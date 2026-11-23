# Códigos fixos da vigilância ambiental de endemias (módulo 35a, ADR 0054;
# plano, Valor fixado 2; contrato §1–§17). Os rótulos moram em
# config/vector_control/domains.yml e os parâmetros técnicos em
# config/vector_control/defaults.yml (VectorControl::Parameters); aqui só o que
# o código usa pelo nome.
module VectorControl
  module Catalog
    ROLES = %w[endemic_coordinator vector_lab].freeze
    ACTIVITIES = %w[li li_t pe ie transmission_block liraa].freeze
    LINKED_ACTIVITIES = { "liraa" => "liraa_draw_item_id", "transmission_block" => "transmission_block_id" }.freeze
    WORK_TYPES = %w[routine pending].freeze
    SITUATIONS = %w[worked closed refused vacant].freeze
    SITUATION_OUTCOME = { "worked" => 1, "refused" => 2, "closed" => 3, "vacant" => 3 }.freeze
    PENDING_SITUATIONS = %w[closed refused].freeze
    PE_PROPERTY = "4".freeze
    IE_PROPERTIES = %w[5 6 7 8 9 10 11 12 13].freeze
    DEPOSIT_GROUPS = %w[A1 A2 B C D1 D2 E].freeze
    DEPOSIT_FIELDS = %w[existing with_water with_larvae eliminated treated].freeze
    DEPOSIT_MAX = 999
    # Listas ausentes = vazias (Q7(4)).
    REQUIRED_KEYS = %w[activity work_type situation educational_action].freeze
    # Q7(3); `deposits` tem no máximo os 7 grupos.
    LIMITS = { deposit_count_max: 999, charges_max: 999, samples_max: 99, larvae_collected_max: 10, measures_max: 20 }.freeze
    METHODS = %w[mechanical focal perifocal spatial].freeze
    PRODUCT_USES = %w[focal perifocal spatial].freeze
    # Módulo 35b (Q11): a vacina antirrábica animal e a coleira também são
    # vector_products, com uma finalidade só (SaveProduct). PRODUCT_USES segue
    # só com as vetoriais (o boletim e o enum da field-sync v1.3.0).
    ALL_PRODUCT_USES = (PRODUCT_USES + Zoonoses::Catalog::PRODUCT_USES).freeze
    UNITS = %w[g ml un].freeze
    CHARGES = (BigDecimal("0.01")..BigDecimal("999"))
    SAMPLE_NUMBERS = (1..99)
    LARVAE = (1..10)
    # Motivos de visita derivados do boletim (HomeVisits::Catalog::NON_RESIDENTIAL_REASONS).
    DERIVED_REASONS = [ 34, 35, 36, 37 ].freeze
    INSPECTION_MAX = 12.hours
    RISK_CLASSES = %w[green yellow red gray purple].freeze
    BLOCK_NUMBER = /\A[0-9A-Za-z-]{1,10}\z/
    PRODUCT_CODE = (1..10)
    PRODUCT_NAME = (1..80)
    CADENCE_DAYS = (7..365)
    CYCLE_NUMBERS = (1..12)
    OVITRAP_NUMBER = /\A[0-9A-Za-z-]{1,12}\z/ # Q7(6)
    CONDITIONS = %w[ok damaged lost dry].freeze
    EGGS = (0..9999)
    NOTE = (10..500)
    ASSIGN_BATCH = 200
    TASK_KINDS = %w[ovitrap_intensification case_resident_elsewhere block_case_without_place].freeze
    LIRAA_MODES = %w[standard half census].freeze
    # Q17: o intervalo dos imóveis do LIRAa é round(1 ÷ fração) do modo
    # (Liraa::Sample.interval), nunca constante: sem HOUSEHOLD_INTERVAL.
    BLOCK_STATUSES = %w[proposed active closed dismissed].freeze
    # Q38: o rótulo de cada grupo de TransmissionBlock::DISEASE_GROUPS (o
    # catalog_spec exige um por código, sem sobra). O módulo 25 não tem grupo.
    DISEASE_GROUP_LABELS = { "arbovirus" => "Arboviroses (dengue, chikungunya, zika)" }.freeze
    UBV_NUMBERS = (1..3)
    # Classe do imóvel no boletim pelo tipo de imóvel do 24a
    # (TerritoryRegistry::Catalog::PROPERTY_TYPES, todos, sem sobra).
    PROPERTY_CLASSES = {
      "R" => %w[1 7 8 9 10 11 99], "C" => %w[2], "TB" => %w[3], "PE" => %w[4], "O" => %w[5 6 12 13]
    }.freeze
    TRAIL_ACCESS = "transmission_block_case".freeze
    # Contrato §17, na ordem da tabela; o 20º (transmission_block_case.moved,
    # Q26(2)) no fim.
    DOMAIN_EVENTS = %w[
      city_block.changed household_vector_profile.changed vector_stock.shortfall_recorded
      vector_stock.shortfall_reconciled ovitrap.installed ovitrap.collected ovitrap_reading.counted
      vector_task.opened vector_task.closed liraa_survey.drawn liraa_survey.closed
      transmission_block.proposed transmission_block.confirmed transmission_block.dismissed
      transmission_block.closed transmission_block_case.address_viewed vector_sample.result_recorded
      vector_parameters.changed vector_product.changed transmission_block_case.moved
    ].freeze
    REPORTS = %w[situations strategic_points production consumption ovitraps liraa blocks].freeze
  end
end
