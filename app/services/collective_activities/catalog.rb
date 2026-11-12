# Códigos fixos da atividade coletiva (módulo 24b, ADR 0052; contrato §4). As
# regras cruzadas por tipo moram em config/ledi/visit_activity_dictionaries.yml
# (`collective_rules`, lidas por CollectiveActivities::Rules); o YAML é a fonte
# da prova e `catalog_spec` confere estes valores contra ele.
module CollectiveActivities
  module Catalog
    CBOS = TerritoryRegistry::Access::REGISTRATION_CBOS.fetch(:collective_activity)
    TYPES = (1..7)
    MEETING_TYPES = [ 1, 2, 3 ].freeze
    PARTICIPANTS_REQUIRED = [ 5, 6 ].freeze
    PRACTICE_TYPE6_ONLY = [ 2, 9, 33 ].freeze
    PROCEDURE_PRACTICE = 30
    SMOKING_PRACTICES = [ 25, 26, 27, 28 ].freeze
    FORBIDDEN_HEALTH_TOPICS = [ 18 ].freeze
    PLACE_TEXT_MAX = 250
    COUNT = (1..999)
    MISTAKEN_REASON = (10..500)
    TRAIL_ACCESS = "collective_activities".freeze
    NOT_GENERATED = %w[
      unit_without_cnes professional_without_cns cbo_not_in_ledi_table city_profile_incomplete
      siaps_deadline_passed participant_without_identifier participant_without_birth_date
      participant_without_sex participant_professional_without_cns place_without_cnes
    ].freeze
    DOMAIN_EVENTS = %w[collective_activity.recorded collective_activity.marked_mistaken].freeze
  end
end
