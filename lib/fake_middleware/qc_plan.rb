require "bigdecimal"

# Plano do controle simulado (ADR 0038; Task 0): aparelhos, material, lote,
# códigos de barras por nível e a bula do lote. Fonte única: a semente de dev
# (lib/lab_qc_crew.rb) cadastra exatamente isto, e o simulado manda valores
# calculados daqui. Sem Rails (o simulado roda sem carregar o app).
module FakeMiddleware
  module QcPlan
    INSTRUMENT = "BIO-01".freeze
    # hl7_equipment_id → [nome, fabricante/modelo]
    INSTRUMENTS = { "BIO-01" => [ "Mindray BS-240", "Mindray" ], "HEM-01" => [ "Sysmex XN-350", "Sysmex" ] }.freeze
    MATERIAL = "Lyphochek Assayed Chemistry Control".freeze
    MANUFACTURER = "Bio-Rad".freeze
    LEVELS = [ "Nível 1", "Nível 2" ].freeze
    LOT = "CQB-2611".freeze
    BARCODES = { "Nível 1" => "CQB2611N1", "Nível 2" => "CQB2611N2" }.freeze
    # código do aparelho → [analyte_key, unidade]
    ANALYTES = { "GLI" => [ "glicose", "mg/dL" ], "CRE" => [ "creatinina", "mg/dL" ] }.freeze
    # bula: nível → código → [média, dp, casas]
    TARGETS = { "Nível 1" => { "GLI" => [ "90", "4.5", 1 ], "CRE" => [ "1.00", "0.06", 2 ] },
                "Nível 2" => { "GLI" => [ "270", "13.5", 1 ], "CRE" => [ "4.80", "0.25", 2 ] } }.freeze
    # Aprovada: z pequenos, de lados opostos, que trocam de sinal a cada dia (nada de 10x ou 4-1s ao longo dos dias).
    APPROVED_Z = { "Nível 1" => 0.4, "Nível 2" => -0.6 }.freeze
    # Reprovada: os dois níveis da glicose acima de +2 dp na mesma corrida → 2-2s entre níveis.
    REJECT_Z = { "Nível 1" => 2.4, "Nível 2" => 2.6 }.freeze
    SCENARIOS = %w[approved reject_2_2s].freeze

    module_function

    def z(scenario, level, code, on)
      return REJECT_Z.fetch(level) if scenario == "reject_2_2s" && code == "GLI"

      APPROVED_Z.fetch(level) * (on.yday.even? ? 1 : -1)
    end

    def value(level, code, z)
      mean, sd, decimals = TARGETS.fetch(level).fetch(code)
      number = (BigDecimal(mean) + (BigDecimal(sd) * BigDecimal(z.to_s))).round(decimals, BigDecimal::ROUND_HALF_UP)
      format("%.#{decimals}f", number)
    end
  end
end
