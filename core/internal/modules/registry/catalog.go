package registry

import (
	"fmt"
	"regexp"
	"sort"
)

// AddressMode tells the wizard whether a connection address is needed.
type AddressMode string

const (
	AddressNone     AddressMode = "none"
	AddressOptional AddressMode = "optional"
	AddressRequired AddressMode = "required"
)

// EntityType describes one kind of object. Adding a type is one catalog entry:
// the API, validation and the desktop wizard are all driven by this data.
type EntityType struct {
	ID          string      `json:"id"`
	Label       string      `json:"label"`
	Description string      `json:"description"`
	Group       string      `json:"group"`
	Icon        string      `json:"icon"`
	AddressMode AddressMode `json:"addressMode"`
	AddressHint string      `json:"addressHint,omitempty"`
	// DefaultCapabilities are assigned on creation; the user can change them later.
	DefaultCapabilities []string `json:"defaultCapabilities"`
}

// Capability is something an object can do. Registry only declares it;
// executing it belongs to Monitoring, Remote, Power, Bots, Network.
type Capability struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Description string `json:"description"`
	// Module that will execute the capability.
	Module string `json:"module"`
}

// RelationKind is a typed edge between two objects.
type RelationKind struct {
	ID          string `json:"id"`
	Label       string `json:"label"`
	Description string `json:"description"`
	// Acyclic kinds reject edges that close a cycle within the same CycleGroup.
	Acyclic    bool   `json:"acyclic"`
	CycleGroup string `json:"-"`
}

// Catalog holds the known types, capabilities and relation kinds.
type Catalog struct {
	types        map[string]EntityType
	capabilities map[string]Capability
	relations    map[string]RelationKind
}

var catalogID = regexp.MustCompile(`^[a-z][a-z0-9_]*(\.[a-z][a-z0-9_]*)*$`)

// NewCatalog returns an empty catalog.
func NewCatalog() *Catalog {
	return &Catalog{
		types:        map[string]EntityType{},
		capabilities: map[string]Capability{},
		relations:    map[string]RelationKind{},
	}
}

// RegisterCapability adds a capability.
func (c *Catalog) RegisterCapability(cp Capability) error {
	if !catalogID.MatchString(cp.ID) || cp.Label == "" {
		return fmt.Errorf("capability %q: invalid id or empty label", cp.ID)
	}
	if _, dup := c.capabilities[cp.ID]; dup {
		return fmt.Errorf("capability %q registered twice", cp.ID)
	}
	c.capabilities[cp.ID] = cp
	return nil
}

// RegisterType adds an entity type; its default capabilities must already exist.
func (c *Catalog) RegisterType(t EntityType) error {
	if !catalogID.MatchString(t.ID) || t.Label == "" {
		return fmt.Errorf("type %q: invalid id or empty label", t.ID)
	}
	if _, dup := c.types[t.ID]; dup {
		return fmt.Errorf("type %q registered twice", t.ID)
	}
	switch t.AddressMode {
	case AddressNone, AddressOptional, AddressRequired:
	default:
		return fmt.Errorf("type %q: invalid addressMode %q", t.ID, t.AddressMode)
	}
	for _, cp := range t.DefaultCapabilities {
		if _, ok := c.capabilities[cp]; !ok {
			return fmt.Errorf("type %q: unknown default capability %q", t.ID, cp)
		}
	}
	if t.DefaultCapabilities == nil {
		t.DefaultCapabilities = []string{}
	}
	c.types[t.ID] = t
	return nil
}

// RegisterRelationKind adds a relation kind.
func (c *Catalog) RegisterRelationKind(k RelationKind) error {
	if !catalogID.MatchString(k.ID) || k.Label == "" {
		return fmt.Errorf("relation kind %q: invalid id or empty label", k.ID)
	}
	if _, dup := c.relations[k.ID]; dup {
		return fmt.Errorf("relation kind %q registered twice", k.ID)
	}
	if k.Acyclic && k.CycleGroup == "" {
		k.CycleGroup = k.ID
	}
	c.relations[k.ID] = k
	return nil
}

// Type looks up an entity type.
func (c *Catalog) Type(id string) (EntityType, bool) { t, ok := c.types[id]; return t, ok }

// Capability looks up a capability.
func (c *Catalog) Capability(id string) (Capability, bool) {
	cp, ok := c.capabilities[id]
	return cp, ok
}

// RelationKind looks up a relation kind.
func (c *Catalog) RelationKind(id string) (RelationKind, bool) {
	k, ok := c.relations[id]
	return k, ok
}

// CycleGroupKinds returns all acyclic kinds sharing a cycle group.
func (c *Catalog) CycleGroupKinds(group string) []string {
	var out []string
	for _, k := range c.relations {
		if k.Acyclic && k.CycleGroup == group {
			out = append(out, k.ID)
		}
	}
	sort.Strings(out)
	return out
}

// Types returns all types in display order (group, then label).
func (c *Catalog) Types() []EntityType {
	out := make([]EntityType, 0, len(c.types))
	for _, t := range c.types {
		out = append(out, t)
	}
	order := map[string]int{"hardware": 0, "network": 1, "software": 2, "virtual": 3}
	sort.Slice(out, func(i, j int) bool {
		if oi, oj := order[out[i].Group], order[out[j].Group]; oi != oj {
			return oi < oj
		}
		return out[i].ID < out[j].ID
	})
	return out
}

// Capabilities returns all capabilities sorted by id.
func (c *Catalog) Capabilities() []Capability {
	out := make([]Capability, 0, len(c.capabilities))
	for _, cp := range c.capabilities {
		out = append(out, cp)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// RelationKinds returns all relation kinds sorted by id.
func (c *Catalog) RelationKinds() []RelationKind {
	out := make([]RelationKind, 0, len(c.relations))
	for _, k := range c.relations {
		out = append(out, k)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].ID < out[j].ID })
	return out
}

// DefaultCatalog is the built-in catalog. It panics on an invalid entry,
// which the tests catch at build time.
func DefaultCatalog() *Catalog {
	c := NewCatalog()
	must := func(err error) {
		if err != nil {
			panic(err)
		}
	}
	for _, cp := range []Capability{
		{"monitoring.metrics", "Метрики", "CPU, память, диски, температуры", "monitoring"},
		{"monitoring.logs", "Журналы", "Сбор и просмотр логов", "monitoring"},
		{"monitoring.heartbeat", "Heartbeat", "Периодический сигнал «я жив»", "monitoring"},
		{"monitoring.http", "HTTP-проверка", "Доступность по HTTP(S)", "monitoring"},
		{"network.ping", "Ping", "Проверка доступности в сети", "network"},
		{"remote.desktop", "Удалённый рабочий стол", "Полный рабочий стол (только desktop-клиенты)", "remote"},
		{"remote.application", "Удалённое приложение", "Управление отдельным окном/приложением", "remote"},
		{"remote.terminal", "Терминал", "Удалённая командная строка", "remote"},
		{"files.transfer", "Передача файлов", "Загрузка и скачивание файлов", "remote"},
		{"power.wake", "Wake-on-LAN", "Включение по сети", "power"},
		{"power.shutdown", "Выключение", "Удалённое выключение", "power"},
		{"power.reboot", "Перезагрузка", "Удалённая перезагрузка", "power"},
		{"power.switch_os", "Смена ОС", "Переключение Ubuntu ↔ Windows", "power"},
		{"docker.manage", "Управление Docker", "Старт/стоп/перезапуск контейнеров", "integrations"},
		{"bot.restart", "Перезапуск бота", "Перезапуск после подтверждения", "bots"},
		{"bot.tasks", "Задания бота", "История и статус заданий", "bots"},
		{"database.check", "Проверка БД", "Доступность и подключения базы данных", "monitoring"},
		{"automation.runs", "Запуски автоматизаций", "История выполнения сценариев", "integrations"},
		{"media.streaming", "Стриминг", "Sunshine/Moonlight и аналоги", "integrations"},
	} {
		must(c.RegisterCapability(cp))
	}

	hw := []string{"monitoring.metrics", "monitoring.logs", "network.ping"}
	for _, t := range []EntityType{
		{ID: "computer", Label: "Компьютер", Description: "Настольный ПК или ноутбук", Group: "hardware", Icon: "computer",
			AddressMode: AddressOptional, AddressHint: "IP или имя хоста в LAN",
			DefaultCapabilities: append(hw, "remote.desktop", "files.transfer", "power.shutdown", "power.reboot")},
		{ID: "server", Label: "Сервер", Description: "Постоянно работающий домашний сервер", Group: "hardware", Icon: "server",
			AddressMode: AddressOptional, AddressHint: "IP или имя хоста в LAN",
			DefaultCapabilities: append(hw, "remote.terminal", "power.shutdown", "power.reboot")},
		{ID: "mobile_device", Label: "Мобильное устройство", Description: "Телефон или планшет", Group: "hardware", Icon: "phone",
			AddressMode: AddressOptional, DefaultCapabilities: []string{"network.ping"}},
		{ID: "television", Label: "Телевизор", Description: "ТВ или ТВ-приставка", Group: "hardware", Icon: "tv",
			AddressMode: AddressOptional, AddressHint: "IP в LAN", DefaultCapabilities: []string{"network.ping"}},
		{ID: "storage", Label: "Хранилище", Description: "Диск, массив или сетевое хранилище", Group: "hardware", Icon: "storage",
			AddressMode: AddressOptional, DefaultCapabilities: []string{"monitoring.metrics"}},
		{ID: "router", Label: "Роутер", Description: "Домашний маршрутизатор", Group: "network", Icon: "router",
			AddressMode: AddressOptional, AddressHint: "Адрес шлюза, например 192.0.2.1", DefaultCapabilities: []string{"network.ping"}},
		{ID: "network_device", Label: "Сетевое устройство", Description: "Коммутатор, точка доступа, VPN-шлюз", Group: "network", Icon: "network",
			AddressMode: AddressOptional, DefaultCapabilities: []string{"network.ping"}},
		{ID: "website", Label: "Сайт", Description: "Веб-сайт или HTTP-сервис", Group: "network", Icon: "web",
			AddressMode: AddressRequired, AddressHint: "URL, например https://example.org",
			DefaultCapabilities: []string{"monitoring.http"}},
		{ID: "telegram_bot", Label: "Telegram-бот", Description: "Бот на Python или другом стеке", Group: "software", Icon: "bot",
			AddressMode: AddressNone, DefaultCapabilities: []string{"monitoring.heartbeat", "monitoring.logs", "bot.tasks"}},
		{ID: "application", Label: "Приложение", Description: "Программа на компьютере", Group: "software", Icon: "app",
			AddressMode: AddressNone, DefaultCapabilities: []string{}},
		{ID: "process", Label: "Процесс", Description: "Фоновый процесс или скрипт", Group: "software", Icon: "process",
			AddressMode: AddressNone, DefaultCapabilities: []string{"monitoring.heartbeat"}},
		{ID: "docker_container", Label: "Docker-контейнер", Description: "Контейнер на хосте Docker", Group: "software", Icon: "container",
			AddressMode: AddressNone, DefaultCapabilities: []string{"monitoring.metrics", "monitoring.logs"}},
		{ID: "database", Label: "База данных", Description: "PostgreSQL, SQLite, MySQL и др.", Group: "software", Icon: "database",
			AddressMode: AddressOptional, AddressHint: "host:port без пароля", DefaultCapabilities: []string{"database.check"}},
		{ID: "service", Label: "Служба", Description: "Системная служба или сервис", Group: "software", Icon: "service",
			AddressMode: AddressOptional, DefaultCapabilities: []string{"monitoring.logs"}},
		{ID: "automation", Label: "Автоматизация", Description: "n8n, cron, сценарий", Group: "software", Icon: "automation",
			AddressMode: AddressOptional, DefaultCapabilities: []string{"automation.runs"}},
		{ID: "virtual_object", Label: "Виртуальный объект", Description: "Логическая группа или понятие без железа", Group: "virtual", Icon: "virtual",
			AddressMode: AddressNone, DefaultCapabilities: []string{}},
		{ID: "custom", Label: "Другое", Description: "Произвольный объект", Group: "virtual", Icon: "custom",
			AddressMode: AddressOptional, DefaultCapabilities: []string{}},
	} {
		t.DefaultCapabilities = append([]string(nil), t.DefaultCapabilities...)
		must(c.RegisterType(t))
	}

	for _, k := range []RelationKind{
		{ID: "runs_on", Label: "работает на", Description: "Программа/бот выполняется на хосте", Acyclic: true, CycleGroup: "placement"},
		{ID: "hosted_by", Label: "размещён на", Description: "Контейнер/сайт размещён на сервере", Acyclic: true, CycleGroup: "placement"},
		{ID: "installed_on", Label: "установлен на", Description: "Приложение установлено на устройство", Acyclic: true, CycleGroup: "placement"},
		{ID: "depends_on", Label: "зависит от", Description: "Не работает без другого объекта", Acyclic: true, CycleGroup: "dependency"},
		{ID: "connected_to", Label: "подключён к", Description: "Сетевое или физическое подключение", Acyclic: false},
		{ID: "controls", Label: "управляет", Description: "Объект управляет другим объектом", Acyclic: false},
		{ID: "custom", Label: "своя связь", Description: "Произвольная связь с подписью", Acyclic: false},
	} {
		must(c.RegisterRelationKind(k))
	}
	return c
}
