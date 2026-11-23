# Códigos fixos do centro de zoonoses (módulo 35b, ADR 0054; plano, Valor
# fixado 2; contrato §1–§16, Q1–Q29). Os rótulos moram em
# config/zoonoses/domains.yml e os parâmetros técnicos em
# config/zoonoses/defaults.yml (Zoonoses::Parameters); aqui só o que o código
# usa pelo nome.
module Zoonoses
  module Catalog
    ROLE = "zoonoses_team".freeze
    VETERINARIAN_CBO = "223305".freeze
    # O agente de combate às endemias (515140) e o ACS (515105), §12.
    FIELD_CBOS = %w[515140 515105].freeze

    # Animal (§1, §2).
    SPECIES = %w[dog cat other].freeze
    VACCINE_SPECIES = %w[dog cat].freeze
    SEXES = %w[male female unknown].freeze
    SIZES = %w[small medium large].freeze
    ANIMAL_STATUSES = %w[active deceased missing transferred].freeze
    NAME = (1..60)
    COAT = (1..40)
    BREED = (1..60)
    MICROCHIP = /\A\d{15}\z/
    REGISTRY_NUMBER = (1..20)

    # Vacinação antirrábica e campanha (§3).
    CAMPAIGN_NAME = (1..80)
    CAMPAIGN_STAGES = %w[planned open closed].freeze
    MODALITIES = %w[house fixed_post routine].freeze
    ROUTINE_BACKDATE_DAYS = 30
    NOTE = (10..500)
    ADVERSE_REMINDER = "Notifique o evento adverso no formulário do Ministério da Saúde (EATAV).".freeze

    # Demandas da ouvidoria (§4, Q13–Q15).
    INSPECTION_NOTE = (10..2000)
    CLOSING_TEXT = (20..4000)
    DEMAND_STATES = %w[open scheduled inspected closed].freeze
    DEMAND_OUTCOMES = %w[resolved guidance not_found referred].freeze
    SUBTYPES = %w[scorpion bat rodent tick aggressive_animal neurological_animal sporotrichosis other].freeze
    SUBJECT_CODE = "zoonoses".freeze
    PLACE_ADDRESS = (10..300)
    DEMAND_KINDS = %w[request report].freeze

    # Observação do animal agressor (§5, Q16).
    OBSERVATION_DISEASE = "acidente_animal_raiva".freeze
    OBSERVATION_STATUSES = %w[notified investigating].freeze
    PLACES = %w[home shelter].freeze
    OBSERVATION_STATES = %w[open closed].freeze
    OBSERVATION_OUTCOMES = %w[healthy died missing rabies_signs sent_to_exam euthanized].freeze

    # Leishmaniose visceral canina e coleira (§6, Q18, Q21).
    SURVEY_KINDS = %w[sample census focus].freeze
    SURVEY_STAGES = %w[draft open closed].freeze
    DPP_RESULTS = %w[reactive non_reactive invalid].freeze
    ELISA_RESULTS = %w[reactive non_reactive inconclusive].freeze
    ELISA_REQUEST = (1..30)
    # Etiqueta da coleta, feita pelo api (Q21): hexadecimal maiúsculo, ou AVUL
    # fora de inquérito.
    LABEL = /\ALV-\d{4}-([0-9A-F]{6}|AVUL)-\d{4}\z/
    LEISH_DECISIONS = %w[tutor_treatment euthanasia refused].freeze
    REMOVAL_REASONS = %w[replaced lost death other].freeze
    COLLAR_DUE_WINDOW = 15

    # Canil, castração e eutanásia (§7).
    ENTRY_KINDS = %w[collection voluntary_surrender observation other].freeze
    EXIT_KINDS = %w[returned adopted death euthanasia transferred].freeze
    EUTHANASIA_REASONS = %w[leishmaniasis rabies_suspect untreatable_suffering public_health_risk other].freeze
    EUTHANASIA_NOTE = (10..1000)
    LEGAL_BASES = %w[cfmv_1000_2012 law_14228_2021].freeze

    # Finalidades dos vector_products do 35a usados pelo 35b (§3, Q11).
    PRODUCT_USES = %w[rabies_vaccine collar].freeze

    # Eventos de domínio (§16, nessa ordem; Q26: as trilhas 21 e 22 no fim).
    # Só ids no payload; declarados sem consumidor
    # (config/initializers/domain_events.rb).
    DOMAIN_EVENTS = %w[
      animal.registered
      animal.changed
      rabies_campaign.changed
      rabies_vaccination.recorded
      rabies_vaccination.cancelled
      zoonoses_demand.opened
      zoonoses_demand.changed
      bite_observation.opened
      bite_observation.closed
      bite_observation.contact_viewed
      leish_survey.changed
      leish_test.recorded
      leish_dog_outcome.recorded
      collar.placed
      collar.removed
      shelter_stay.opened
      shelter_stay.closed
      neutering.recorded
      euthanasia.recorded
      zoonoses_parameters.changed
      animal.viewed
      zoonoses_demand.viewed
    ].freeze

    REPORTS = %w[rabies_weekly rabies_modalities demands observations leish shelter].freeze
  end
end
