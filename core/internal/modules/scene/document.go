// Package scene stores versioned scene documents (the isometric house) for
// AER clients. Core only stores and validates the data; rendering happens on
// clients. Scene never reads Registry tables: entity bindings are UUIDs that
// clients resolve through the Registry API (a dangling binding is allowed and
// shown as "object not found").
//
// The format is specified in contracts/scene.schema.json and docs/SCENE_FORMAT.md.
package scene

import (
	"bytes"
	"encoding/json"
	"fmt"
	"math"
	"regexp"
	"unicode/utf8"

	"aerhome/core/internal/foundation/ids"
)

// CurrentSchemaVersion is the scene format version this Core writes.
const CurrentSchemaVersion = 1

// Document is scene format v1.
type Document struct {
	SchemaVersion int               `json:"schemaVersion"`
	SceneID       string            `json:"sceneId"`
	Name          string            `json:"name"`
	Demo          bool              `json:"demo"`
	Projection    string            `json:"projection"`
	Assets        []Asset           `json:"assets"`
	Rooms         []Room            `json:"rooms"`
	Objects       []Object          `json:"objects"`
	Metadata      map[string]string `json:"metadata"`
}

type Size2 struct {
	W float64 `json:"w"`
	D float64 `json:"d"`
}

type Point2 struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
}

type Point3 struct {
	X float64 `json:"x"`
	Y float64 `json:"y"`
	Z float64 `json:"z"`
}

type Art struct {
	Kind   string `json:"kind"`
	Ref    string `json:"ref"`
	Status string `json:"status"`
}

type Asset struct {
	ID        string  `json:"id"`
	Label     string  `json:"label"`
	Footprint Size2   `json:"footprint"`
	Height    float64 `json:"height"`
	Art       Art     `json:"art"`
}

// RoomStyle names materials from the client's material catalog. Core checks
// only the identifier shape, so new materials need no Core release; an
// unknown material is drawn with a fallback by clients.
type RoomStyle struct {
	Floor string `json:"floor"`
	Wall  string `json:"wall"`
	// Light is an optional lighting preset (contract 0.5.0, additive).
	Light string `json:"light,omitempty"`
}

type Room struct {
	ID         string            `json:"id"`
	Name       string            `json:"name"`
	Kind       string            `json:"kind"`
	Origin     Point2            `json:"origin"`
	Size       Size2             `json:"size"`
	WallHeight float64           `json:"wallHeight"`
	Style      RoomStyle         `json:"style"`
	Metadata   map[string]string `json:"metadata"`
}

type EntityBinding struct {
	EntityID string `json:"entityId"`
	Role     string `json:"role"`
}

// VisualState holds only explicitly marked demo states; real states come from
// Monitoring at runtime and are never stored in the scene.
type VisualState struct {
	Demo string `json:"demo"`
}

type Object struct {
	ID            string            `json:"id"`
	RoomID        string            `json:"roomId"`
	AssetID       string            `json:"assetId"`
	Label         string            `json:"label"`
	Position      Point3            `json:"position"`
	Rotation      int               `json:"rotation"`
	Scale         float64           `json:"scale"`
	Layer         string            `json:"layer"`
	EntityBinding *EntityBinding    `json:"entityBinding"`
	VisualState   *VisualState      `json:"visualState"`
	Metadata      map[string]string `json:"metadata"`
}

// Limits shared with contracts/scene.schema.json and the desktop codec.
const (
	maxAssets      = 500
	maxRooms       = 64
	maxObjects     = 2000
	maxCoordinate  = 500.0
	maxRoomSize    = 200.0
	maxFootprint   = 50.0
	maxHeight      = 40.0
	maxWallHeight  = 20.0
	minScale       = 0.25
	maxScale       = 4.0
	maxMetaEntries = 16
	eps            = 1e-6
)

var (
	assetIDPattern = regexp.MustCompile(`^[a-z0-9_]+(/[a-z0-9_.-]+)*$`)
	roomKinds      = set("office", "living", "server", "network", "automation", "bedroom", "kitchen", "custom")
	materialID     = regexp.MustCompile(`^[a-z][a-z0-9_]{0,31}$`)
	layers         = set("floor", "object", "wall")
	artKinds       = set("procedural", "sprite")
	artStatuses    = set("placeholder", "final")
	bindingRoles   = set("primary", "secondary")
	visualStates   = set("online", "offline", "warning", "critical", "unknown", "loading", "archived")
	rotations      = map[int]bool{0: true, 90: true, 180: true, 270: true}
)

func set(items ...string) map[string]bool {
	m := map[string]bool{}
	for _, i := range items {
		m[i] = true
	}
	return m
}

// Issues maps a JSON path (e.g. "objects[3].position.x") to a message.
type Issues map[string]string

func (is Issues) add(path, format string, args ...any) {
	if _, exists := is[path]; !exists {
		is[path] = fmt.Sprintf(format, args...)
	}
}

// ValidationError lists every problem found in a document.
type ValidationError struct{ Issues Issues }

func (e *ValidationError) Error() string { return fmt.Sprintf("invalid scene: %v", e.Issues) }

// Decode parses and validates a scene document strictly (unknown fields are
// rejected), upgrading older schema versions when an upgrader exists.
func Decode(raw []byte) (Document, error) {
	var probe struct {
		SchemaVersion int `json:"schemaVersion"`
	}
	if err := json.Unmarshal(raw, &probe); err != nil {
		return Document{}, &ValidationError{Issues{"": "Документ сцены не является корректным JSON: " + err.Error()}}
	}
	raw, err := upgrade(probe.SchemaVersion, raw)
	if err != nil {
		return Document{}, err
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	var doc Document
	if err := dec.Decode(&doc); err != nil {
		return Document{}, &ValidationError{Issues{"": "Структура сцены не соответствует схеме v1: " + err.Error()}}
	}
	if err := doc.Validate(); err != nil {
		return Document{}, err
	}
	return doc, nil
}

// upgraders convert version N to N+1. Empty while only v1 exists; adding v2
// means adding upgraders[1] and bumping CurrentSchemaVersion.
var upgraders = map[int]func([]byte) ([]byte, error){}

func upgrade(version int, raw []byte) ([]byte, error) {
	if version < 1 || version > CurrentSchemaVersion {
		return nil, &ValidationError{Issues{"schemaVersion": fmt.Sprintf(
			"Версия схемы %d не поддерживается (этот Core понимает 1…%d)", version, CurrentSchemaVersion)}}
	}
	for v := version; v < CurrentSchemaVersion; v++ {
		up, ok := upgraders[v]
		if !ok {
			return nil, &ValidationError{Issues{"schemaVersion": fmt.Sprintf("Нет миграции со схемы %d", v)}}
		}
		var err error
		if raw, err = up(raw); err != nil {
			return nil, err
		}
	}
	return raw, nil
}

func finite(v float64) bool { return !math.IsNaN(v) && !math.IsInf(v, 0) }

func text(is Issues, path, v string, min, max int) {
	n := utf8.RuneCountInString(v)
	if n < min || n > max {
		if min > 0 && n == 0 {
			is.add(path, "Обязательное поле")
		} else {
			is.add(path, "Длина должна быть от %d до %d символов", min, max)
		}
	}
}

func metadata(is Issues, path string, m map[string]string) {
	if len(m) > maxMetaEntries {
		is.add(path, "Не больше %d записей", maxMetaEntries)
	}
	for k, v := range m {
		if k == "" || utf8.RuneCountInString(k) > 64 || utf8.RuneCountInString(v) > 512 {
			is.add(path+"."+k, "Ключ до 64 символов, значение до 512")
		}
	}
}

func inRange(is Issues, path string, v, lo, hi float64) bool {
	if !finite(v) || v < lo-eps || v > hi+eps {
		is.add(path, "Значение должно быть в диапазоне %g…%g", lo, hi)
		return false
	}
	return true
}

// Footprint returns the object's footprint after rotation and scale.
func (o Object) Footprint(a Asset) Size2 {
	w, d := a.Footprint.W*o.Scale, a.Footprint.D*o.Scale
	if o.Rotation == 90 || o.Rotation == 270 {
		w, d = d, w
	}
	return Size2{W: w, D: d}
}

// Validate checks every rule of scene format v1.
func (d Document) Validate() error {
	is := Issues{}
	if d.SchemaVersion != CurrentSchemaVersion {
		is.add("schemaVersion", "Ожидается %d", CurrentSchemaVersion)
	}
	if !ids.Valid(d.SceneID) {
		is.add("sceneId", "Нужен UUID в нижнем регистре")
	}
	text(is, "name", d.Name, 1, 120)
	if d.Projection != "isometric-2:1" {
		is.add("projection", "Поддерживается только isometric-2:1")
	}
	metadata(is, "metadata", d.Metadata)

	assets := map[string]Asset{}
	if len(d.Assets) > maxAssets {
		is.add("assets", "Не больше %d ассетов", maxAssets)
	}
	for i, a := range d.Assets {
		p := fmt.Sprintf("assets[%d]", i)
		if !assetIDPattern.MatchString(a.ID) || len(a.ID) > 64 {
			is.add(p+".id", "Идентификатор ассета: латиница, цифры, _ . - и /")
		} else if _, dup := assets[a.ID]; dup {
			is.add(p+".id", "Ассет %q объявлен дважды", a.ID)
		}
		assets[a.ID] = a
		text(is, p+".label", a.Label, 0, 120)
		inRange(is, p+".footprint.w", a.Footprint.W, 0.05, maxFootprint)
		inRange(is, p+".footprint.d", a.Footprint.D, 0.05, maxFootprint)
		inRange(is, p+".height", a.Height, 0.01, maxHeight)
		if !artKinds[a.Art.Kind] {
			is.add(p+".art.kind", "procedural или sprite")
		}
		text(is, p+".art.ref", a.Art.Ref, 1, 128)
		if !artStatuses[a.Art.Status] {
			is.add(p+".art.status", "placeholder или final")
		}
	}

	rooms := map[string]Room{}
	if len(d.Rooms) == 0 || len(d.Rooms) > maxRooms {
		is.add("rooms", "Нужна хотя бы одна комната (не больше %d)", maxRooms)
	}
	for i, r := range d.Rooms {
		p := fmt.Sprintf("rooms[%d]", i)
		if !ids.Valid(r.ID) {
			is.add(p+".id", "Нужен UUID в нижнем регистре")
		} else if _, dup := rooms[r.ID]; dup {
			is.add(p+".id", "Комната с таким id уже есть")
		}
		text(is, p+".name", r.Name, 1, 80)
		if !roomKinds[r.Kind] {
			is.add(p+".kind", "Неизвестный вид комнаты")
		}
		inRange(is, p+".origin.x", r.Origin.X, -maxCoordinate, maxCoordinate)
		inRange(is, p+".origin.y", r.Origin.Y, -maxCoordinate, maxCoordinate)
		inRange(is, p+".size.w", r.Size.W, 1, maxRoomSize)
		inRange(is, p+".size.d", r.Size.D, 1, maxRoomSize)
		inRange(is, p+".wallHeight", r.WallHeight, 0, maxWallHeight)
		if !materialID.MatchString(r.Style.Floor) {
			is.add(p+".style.floor", "Идентификатор материала пола: a-z, цифры, _ (до 32)")
		}
		if !materialID.MatchString(r.Style.Wall) {
			is.add(p+".style.wall", "Идентификатор материала стен: a-z, цифры, _ (до 32)")
		}
		if r.Style.Light != "" && !materialID.MatchString(r.Style.Light) {
			is.add(p+".style.light", "Идентификатор освещения: a-z, цифры, _ (до 32)")
		}
		metadata(is, p+".metadata", r.Metadata)
		for j, other := range d.Rooms[:i] {
			if overlaps(r, other) {
				is.add(p, "Комната пересекается с rooms[%d]", j)
			}
		}
		rooms[r.ID] = r
	}

	objectIDs := map[string]bool{}
	if len(d.Objects) > maxObjects {
		is.add("objects", "Не больше %d объектов", maxObjects)
	}
	for i, o := range d.Objects {
		p := fmt.Sprintf("objects[%d]", i)
		if !ids.Valid(o.ID) {
			is.add(p+".id", "Нужен UUID в нижнем регистре")
		} else if objectIDs[o.ID] {
			is.add(p+".id", "Объект с таким id уже есть")
		}
		objectIDs[o.ID] = true
		room, roomOK := rooms[o.RoomID]
		if !roomOK {
			is.add(p+".roomId", "Комната не найдена")
		}
		asset, assetOK := assets[o.AssetID]
		if !assetOK {
			is.add(p+".assetId", "Ассет не объявлен в assets")
		}
		text(is, p+".label", o.Label, 0, 120)
		if !rotations[o.Rotation] {
			is.add(p+".rotation", "Поворот: 0, 90, 180 или 270")
		}
		scaleOK := inRange(is, p+".scale", o.Scale, minScale, maxScale)
		if !layers[o.Layer] {
			is.add(p+".layer", "Слой: floor, object или wall")
		}
		inRange(is, p+".position.z", o.Position.Z, 0, maxHeight)
		xOK := inRange(is, p+".position.x", o.Position.X, 0, maxRoomSize)
		yOK := inRange(is, p+".position.y", o.Position.Y, 0, maxRoomSize)
		if roomOK && assetOK && scaleOK && xOK && yOK && rotations[o.Rotation] {
			fp := o.Footprint(asset)
			if o.Position.X+fp.W > room.Size.W+eps || o.Position.Y+fp.D > room.Size.D+eps {
				is.add(p+".position", "Объект выходит за пределы комнаты %q", room.Name)
			}
		}
		if b := o.EntityBinding; b != nil {
			if !ids.Valid(b.EntityID) {
				is.add(p+".entityBinding.entityId", "Нужен UUID сущности Registry")
			}
			if !bindingRoles[b.Role] {
				is.add(p+".entityBinding.role", "primary или secondary")
			}
		}
		if vs := o.VisualState; vs != nil {
			switch {
			case !visualStates[vs.Demo]:
				is.add(p+".visualState.demo", "Неизвестное состояние")
			case !d.Demo:
				is.add(p+".visualState", "Тестовые состояния допустимы только в демо-сцене")
			case o.EntityBinding != nil:
				is.add(p+".visualState", "У привязанного объекта не может быть тестового состояния")
			}
		}
		metadata(is, p+".metadata", o.Metadata)
	}
	if len(is) > 0 {
		return &ValidationError{Issues: is}
	}
	return nil
}

func overlaps(a, b Room) bool {
	return a.Origin.X < b.Origin.X+b.Size.W-eps && b.Origin.X < a.Origin.X+a.Size.W-eps &&
		a.Origin.Y < b.Origin.Y+b.Size.D-eps && b.Origin.Y < a.Origin.Y+a.Size.D-eps
}

// Canonical re-encodes a validated document (stable field order, no unknown data).
func (d Document) Canonical() []byte {
	if d.Metadata == nil {
		d.Metadata = map[string]string{}
	}
	for i := range d.Rooms {
		if d.Rooms[i].Metadata == nil {
			d.Rooms[i].Metadata = map[string]string{}
		}
	}
	for i := range d.Objects {
		if d.Objects[i].Metadata == nil {
			d.Objects[i].Metadata = map[string]string{}
		}
	}
	if d.Assets == nil {
		d.Assets = []Asset{}
	}
	if d.Objects == nil {
		d.Objects = []Object{}
	}
	b, _ := json.Marshal(d)
	return b
}
