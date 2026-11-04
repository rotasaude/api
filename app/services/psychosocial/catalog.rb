# Valores fixos do CAPS (ADR 0049; plano, Valor fixado 4; contrato P12, P14,
# P25). Os limites de texto seguem o contrato: acima do máximo → `too_long`;
# vazio ou abaixo do mínimo → `invalid_request` (text_problem), sempre com o
# path. As listas da RAAS (origens, destinos, substâncias) moram no raas.yml.
module Psychosocial
  module Catalog
    REFERRAL_PRIORITIES = %w[routine priority].freeze
    REFERRAL_STATUSES = %w[pending received].freeze
    RECEPTION_OUTCOMES = %w[enrolled referred_elsewhere no_follow_up].freeze
    PLACES = %w[caps territory].freeze
    INSTRUMENTS = %w[raas_psi bpa_c bpa_i].freeze
    INSTRUMENT_CODES = { "09" => "raas_psi", "02" => "bpa_i", "01" => "bpa_c" }.freeze
    GROUP_KINDS = %w[group workshop assembly].freeze
    INTENSITIES = %w[intensive semi_intensive non_intensive].freeze
    MONTHLY_STATUSES = %w[open closed exported].freeze
    ACTION_ORIGINS = %w[manual reception night_stay matrix_support].freeze
    # Prefixo SIGTAP das ações do CAPS oferecidas no GET /psychosocial/options
    # (grupo 03, subgrupo 01, forma 08: atendimento/acompanhamento
    # psicossocial). Só o recorte da tela: a crítica da ação (Task 7) lê a
    # SIGTAP inteira da competência.
    PROCEDURE_PREFIX = "030108".freeze
    WEEKDAYS = (1..7) # ISO, 1 = segunda
    QUANTITY = (1..999)

    # Textos (P12; mínimos do P25).
    NOTES = (1..4000)
    CLINICAL_TEXT = NOTES
    NEEDS = (1..4000)
    REFERRAL_REASON = (10..2000)
    CANCEL_REASON = (10..2000)
    SHARED_TEXT = (10..2000)
    GOAL_TEXT = (1..500)
    TOPIC = (1..200)
    FAMILY_NAME = (3..120)
    # Reabertura do mês, reavaliação do limite noturno e saída do leito (P25).
    REASON = (10..500)
    NAME_MAX = 120
    TOPIC_MAX = TOPIC.max
    BED_LABEL = (1..20)
    BED_LABEL_MAX = BED_LABEL.max

    MAX_GOALS = 20
    MAX_SECONDARY_CIDS = 4
    CAPACITY = (1..100)
    MAX_EXPECTED_STAY_DAYS = 30
    AUTHORIZATION = /\A\d{13}\z/
    REVIEW_DAYS = (30..365)
    DEFAULT_REVIEW_DAYS = 90
    # Limites do acolhimento noturno por modalidade (PsychosocialSetting#night_limits):
    # CAPS III por sequência e alternadas; AD III/IV pelo total na janela.
    DEFAULT_NIGHT_LIMITS = { "caps_iii" => { "consecutive" => 7, "alternate" => 10, "window_days" => 30 },
                             "caps_ad_iii" => { "total" => 14, "window_days" => 30 },
                             "caps_ad_iv" => { "total" => 14, "window_days" => 30 } }.freeze
    NIGHT_LIMIT_KEYS = DEFAULT_NIGHT_LIMITS.transform_values { |limits| limits.keys.sort.freeze }.freeze
    WINDOW_DAYS = (7..90)
    NIGHT_COUNT = (1..WINDOW_DAYS.max)
    TRAIL_ACCESS = "psychosocial".freeze

    # Pendências que bloqueiam o fechamento do mês (§6; P14) e avisos que não bloqueiam.
    PROBLEM_CODES = %w[patient_cns_missing phone_missing homeless_missing professional_cns_missing professional_not_in_cnes
                       cid_missing action_out_of_rule night_stay_open].freeze
    WARNING_CODES = %w[no_actions].freeze

    module_function

    # -> nil (texto aceito) | { error: "invalid_request" | "too_long", path: }.
    # Conta os caracteres sem os espaços das pontas; quem grava usa o mesmo strip.
    def text_problem(value, range, path)
      return { error: "invalid_request", path: path } unless value.is_a?(String)

      length = value.strip.length
      return { error: "too_long", path: path } if length > range.max
      return { error: "invalid_request", path: path } if length < [ range.min, 1 ].max

      nil
    end
  end
end
