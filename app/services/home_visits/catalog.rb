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
    # Proibidos só para o sexo masculino (male_forbidden_reasons do YAML; Q35).
    MALE_FORBIDDEN_REASONS = [ 5, 6 ].freeze
    # Residencial sem pessoa (Q34/Q40) e os que levam o documento do responsável familiar (Q40).
    WITHOUT_PERSON_ALLOWED_REASONS = [ 1, 27, 28 ].freeze
    RESPONSIBLE_DOCUMENT_REASONS = [ 29, 34, 35, 36, 37 ].freeze
    # Visitas válidas por folha (visitasDomiciliares, máximo 99): a 100ª fecha a folha cheia.
    MAX_VISITS_PER_SHEET = 99
    NOTE_MAX = 500
    WITHDRAWAL_REASON = (10..500)
    ORIGINS = %w[dashboard field_app].freeze
    CLOSED_BY = %w[user job full].freeze
    TRAIL_ACCESS = "home_visits".freeze
    FIELD_TRAIL_ACCESS = "field_sync".freeze
    # As faixas e casas das medidas ficam só no YAML (HomeVisits::Rules::MEASUREMENTS).
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
