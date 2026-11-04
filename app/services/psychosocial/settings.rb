# Parâmetros do CAPS da cidade (ADR 0049; contrato §3): a linha 1 de
# psychosocial_settings, criada com os padrões do banco quando falta (o banco
# montado pelo dump não leva o INSERT da migração; ruling do controlador).
# Sem cache: lidos por requisição.
module Psychosocial
  module Settings
    module_function

    def current = PsychosocialSetting.current

    # Forma do contrato §3.
    def json(setting)
      { "night_limits" => setting.night_limits, "care_plan_review_days" => setting.care_plan_review_days }
    end
  end
end
