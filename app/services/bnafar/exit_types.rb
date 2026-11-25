# DM12: tipo de saída do movimento (módulo 27b, Valor 5; R1, R2). Puro: o `loss_code` da
# StockAdjustment e a saída externa chegam lidos pelo chamador.
#
# Devolve: String (código DM12) | :ignored | :reversal | :not_exit | nil.
# nil = movimento negativo sem mapa (vira a pendência `exit_type_missing`).
module Bnafar
  module ExitTypes
    IGNORED = %w[dispensing opening_reversal].freeze
    REVERSAL_KINDS = %w[immunization_reversal vector_application_reversal animal_vaccination_reversal].freeze

    module_function

    # `adjustment` responde a `loss_code` (ou é o próprio código); `external_exit` responde a
    # `exit_type` (ou é o próprio código).
    def for(movement, adjustment: nil, external_exit: nil)
      kind = movement.kind.to_s
      return :ignored if IGNORED.include?(kind)
      return :reversal if REVERSAL_KINDS.include?(kind)
      return external_code(external_exit) if kind == "external_exit"
      return (negative?(movement) ? map.fetch("adjustment") : :not_exit) if kind == "adjustment"
      return :not_exit if Pharmacy::Catalog::POSITIVE_KINDS.include?(kind)
      return (kind == "loss" ? loss_override(kind, adjustment) : map.fetch(kind)) if map.key?(kind)

      negative?(movement) ? nil : :not_exit
    end

    def loss_override(kind, adjustment)
      code = adjustment.respond_to?(:loss_code) ? adjustment.loss_code : adjustment
      Domains.mappings.fetch("loss_code_exit_types")[code.to_s] || map.fetch(kind)
    end

    def external_code(external_exit)
      code = external_exit.respond_to?(:exit_type) ? external_exit.exit_type : external_exit
      code.presence
    end

    def negative?(movement) = movement.quantity.to_d.negative?
    def map = Domains.mappings.fetch("exit_types")
    private_class_method :loss_override, :external_code, :negative?, :map
  end
end
