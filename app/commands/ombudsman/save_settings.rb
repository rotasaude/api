# PATCH /ombudsman/settings (ADR 0051; contrato §7): prazos e teto da cidade.
# Cada chave é opcional; inteiros de 1 a 120 (o teto diário da denúncia
# anônima, de 1 a 1000); chave desconhecida ou valor fora da faixa → 422 com o
# `path` (só o NOME da chave) e todas as recusas em `problems`. Vale a
# configuração vigente para as manifestações abertas (Q17).
module Ombudsman
  module SaveSettings
    DAY_KEYS = %w[response_days extension_days urgent_days complement_days forwarding_days forwarding_extension_days warning_days].freeze
    CAP_KEY = "anonymous_daily_cap".freeze
    KEYS = (DAY_KEYS + [ CAP_KEY ]).freeze
    DAYS = (1..120)
    CAP = (1..1000)

    module_function

    # Os oito inteiros, na ordem do contrato.
    def json(setting) = KEYS.index_with { |key| setting[key] }

    # -> Result.ok(settings: <os oito inteiros>) | fail(:invalid_request, details: { path:, problems: })
    def call(attrs:, by:)
      attrs = attrs.to_h.stringify_keys
      problems = attrs.filter_map do |key, value|
        range = key == CAP_KEY ? CAP : DAYS
        path = key[0, Input::KEY_PATH_MAX]
        { error: "invalid_request", path: path } unless KEYS.include?(key) && value.is_a?(Integer) && range.cover?(value)
      end
      return Result.fail(:invalid_request, details: { path: problems.first[:path], problems: problems }) if problems.any?

      Settings.ensure_defaults!
      OmbudsmanSetting.transaction(requires_new: true) do
        setting = OmbudsmanSetting.lock.find(1)
        setting.assign_attributes(attrs)
        if setting.changed?
          setting.updated_by_user = by
          setting.save!
        end
        Result.ok(settings: json(setting))
      end
    end
  end
end
