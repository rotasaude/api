# Domínio de um local ou lote do razão de estoque (ADR 0047, Desvios 4 e 5):
# medicamento (27a: `central`, `unit`), imunobiológico (29: `cold_chain_central`,
# `vaccine_room`) ou insumo de campo da vigilância ambiental (35a, ADR 0054,
# Q4: `vector_control`). Cada lote só entra em local do seu domínio
# (`item_not_allowed_here`), nos dois sentidos. O interruptor que vale para o
# local é o do domínio: `pharmacy`, `vaccination` ou `vector_control`; o
# domínio VECTOR_CONTROL também abre com o `zoonoses` utilizável (35b, Q3 e
# Q11: a vacina antirrábica animal e a coleira moram no estoque do 35a).
module Stock
  module Domain
    MEDICATION = "medication".freeze
    IMMUNOBIOLOGICAL = "immunobiological".freeze
    VECTOR_CONTROL = "vector_control".freeze
    IMMUNOBIOLOGICAL_LOCATION_KINDS = %w[cold_chain_central vaccine_room].freeze
    VECTOR_CONTROL_LOCATION_KINDS = %w[vector_control].freeze
    FEATURES = { MEDICATION => "pharmacy", IMMUNOBIOLOGICAL => "vaccination", VECTOR_CONTROL => "vector_control" }.freeze

    module_function

    # -> "medication" | "immunobiological" | "vector_control"
    def for(location)
      return IMMUNOBIOLOGICAL if IMMUNOBIOLOGICAL_LOCATION_KINDS.include?(location.kind)
      return VECTOR_CONTROL if VECTOR_CONTROL_LOCATION_KINDS.include?(location.kind)

      MEDICATION
    end

    # -> "pharmacy" | "vaccination" | "vector_control"
    def feature_for(location) = FEATURES.fetch(self.for(location))

    def medication?(location) = self.for(location) == MEDICATION
    def immunobiological?(location) = self.for(location) == IMMUNOBIOLOGICAL
    def vector_control?(location) = self.for(location) == VECTOR_CONTROL

    # -> "medication" | "immunobiological" | "vector_control"
    def of_lot(lot)
      return IMMUNOBIOLOGICAL if lot.immunobiological?
      return VECTOR_CONTROL if lot.vector_control?

      MEDICATION
    end

    # O lote é do domínio do local.
    def allows?(location, lot) = self.for(location) == of_lot(lot)

    # Interruptor do domínio utilizável na cidade (VECTOR_CONTROL: o
    # vector_control ou o zoonoses, VectorControl::Gate.supplies_usable?).
    def usable?(city, domain)
      case domain
      when IMMUNOBIOLOGICAL then Vaccination::Gate.usable?(city)
      when VECTOR_CONTROL then VectorControl::Gate.supplies_usable?(city)
      else Pharmacy::Gate.usable?(city)
      end
    end
  end
end
