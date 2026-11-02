# Domínio de um local ou lote do razão de estoque (ADR 0047, Desvios 4 e 5):
# medicamento (27a: `central`, `unit`) ou imunobiológico (29: `cold_chain_central`,
# `vaccine_room`). Vacina só entra em local de vacina e medicamento nunca entra
# nele (`item_not_allowed_here`). O interruptor que vale para o local é o do
# domínio: `pharmacy` ou `vaccination`.
module Stock
  module Domain
    MEDICATION = "medication".freeze
    IMMUNOBIOLOGICAL = "immunobiological".freeze
    IMMUNOBIOLOGICAL_LOCATION_KINDS = %w[cold_chain_central vaccine_room].freeze
    FEATURES = { MEDICATION => "pharmacy", IMMUNOBIOLOGICAL => "vaccination" }.freeze

    module_function

    # -> "medication" | "immunobiological"
    def for(location) = IMMUNOBIOLOGICAL_LOCATION_KINDS.include?(location.kind) ? IMMUNOBIOLOGICAL : MEDICATION

    # -> "pharmacy" | "vaccination"
    def feature_for(location) = FEATURES.fetch(self.for(location))

    def immunobiological?(location) = self.for(location) == IMMUNOBIOLOGICAL

    # -> "medication" | "immunobiological"
    def of_lot(lot) = lot.immunobiological? ? IMMUNOBIOLOGICAL : MEDICATION

    # O lote é do domínio do local.
    def allows?(location, lot) = self.for(location) == of_lot(lot)

    # Interruptor do domínio utilizável na cidade.
    def usable?(city, domain) = domain == IMMUNOBIOLOGICAL ? Vaccination::Gate.usable?(city) : Pharmacy::Gate.usable?(city)
  end
end
