import '../../core_api/core_client.dart';

/// Human-readable message for a Registry operation failure.
String describeError(Object error) {
  if (error is CoreUnreachable) {
    return 'AER Core недоступен. Изменения не сохранены — повторите, когда связь восстановится.';
  }
  if (error is CoreApiException) {
    if (error.isUnauthorized) {
      return 'Нет доступа к AER Core: токен не найден или отклонён.';
    }
    if (error.isValidation) {
      final fields = error.fieldErrors.values;
      return fields.isEmpty ? error.message : fields.join('\n');
    }
    if (error.isConflict) {
      return switch (error.conflictReason) {
        'revision_mismatch' => 'Объект изменился в другом окне или на другом устройстве. Обновите данные и повторите.',
        _ => error.message,
      };
    }
    if (error.isNotFound) return 'Объект не найден — возможно, его уже нет.';
    if (error.message.isNotEmpty) return error.message;
    return 'Ошибка ${error.code}';
  }
  return 'Неожиданная ошибка: $error';
}
