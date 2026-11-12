# Códigos fixos da visita domiciliar (módulo 24b, ADR 0052; contrato §1–§3). Os
# domínios e as regras da ficha moram em config/ledi/visit_activity_dictionaries.yml
# (a prova); aqui só o que o código usa pelo nome. Dentro de HomeVisits, `Access::`
# resolveria para HomeVisits::Access: REGISTRATION_CBOS vem do 24a por nome inteiro.
module HomeVisits
  module Catalog
    HOME_VISIT_CBOS = TerritoryRegistry::Access::REGISTRATION_CBOS.fetch(:home_visit)
    ACS_CBO = "515105"
    CARE_LINE_CBOS = %w[515105 322255].freeze
    OUTCOMES = { 1 => "done", 2 => "refused", 3 => "absent" }.freeze
    SUBJECTS = %w[resident family_responsible none].freeze
    NON_RESIDENTIAL = %w[2 3 4 5 6 12 13].freeze
    RESIDENTIAL = %w[1 7 8 9 10 11 99].freeze
    NON_RESIDENTIAL_REASONS = [ 1, 27, 28, 31, 34, 35, 36, 37 ].freeze
    # Proibidos para o masculino (male_forbidden_reasons do YAML).
    FEMALE_ONLY_REASONS = [ 5, 6 ].freeze
    MAX_VISITS_PER_DAY = 99
    NOTE_MAX = 500
    WITHDRAWAL_REASON = (10..500)
    ORIGINS = %w[dashboard field_app].freeze
    CLOSED_BY = %w[user job full].freeze
    TRAIL_ACCESS = "home_visits".freeze
    FIELD_TRAIL_ACCESS = "field_sync".freeze
    # chave => [faixa, casas decimais] (faixas do dicionario-fvd.html; YAML `measurements`).
    MEASUREMENTS = {
      "weight_kg" => [ (0.5..500), 3 ], "height_cm" => [ (20..250), 1 ],
      "systolic" => [ (0..999), 0 ], "diastolic" => [ (0..999), 0 ],
      "temperature_c" => [ (20..45), 1 ], "glucose_mg_dl" => [ (0..800), 0 ],
      "glucose_type" => [ nil, 0 ]
    }.freeze
    NOT_GENERATED = %w[
      unit_without_cnes professional_without_cns cbo_not_in_ledi_table city_profile_incomplete
      siaps_deadline_passed patient_without_identifier citizen_without_birth_date citizen_without_sex
    ].freeze
    DOMAIN_EVENTS = %w[
      home_visit.recorded home_visit.withdrawn home_visit_day.closed
      micro_area.field_assignment_changed field_device.registered field_device.revoked
    ].freeze
  end
end
