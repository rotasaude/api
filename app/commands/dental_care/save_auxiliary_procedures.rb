# Lista de procedimentos do TSB/ASB (ADR 0046, Desvio 8): substitui a lista
# inteira numa transação. Até 100 códigos SIGTAP de 10 dígitos; repetido vale
# uma vez. Evento `dental.auxiliary_procedures_changed` (user_id, count).
module DentalCare
  module SaveAuxiliaryProcedures
    MAX = 100
    CODE = /\A\d{10}\z/

    module_function

    # codes: a lista do corpo (qualquer coisa). -> Result.ok(codes: [...]) | fail(:invalid_request, details: { path: })
    def call(codes:, by:)
      return refuse("procedures") unless codes.is_a?(Array) && codes.size <= MAX

      bad = codes.index { |code| !(code.is_a?(String) && code.match?(CODE)) }
      return refuse("procedures[#{bad}].sigtap") if bad

      codes = codes.uniq
      DentalAuxiliaryProcedure.transaction(requires_new: true) do
        DentalAuxiliaryProcedure.where.not(procedure_code: codes).delete_all
        now = Time.current
        missing = codes - DentalAuxiliaryProcedure.where(procedure_code: codes).pluck(:procedure_code)
        if missing.any?
          DentalAuxiliaryProcedure.insert_all(missing.map { |code| { procedure_code: code, created_by_user_id: by.id, created_at: now } })
        end
        DomainEvents.publish("dental.auxiliary_procedures_changed", user_id: by.id, count: codes.size)
        Result.ok(codes: codes)
      end
    end

    def refuse(path) = Result.fail(:invalid_request, details: { path: path, problems: [ { path: path, error: "invalid_request" } ] })
    private_class_method :refuse
  end
end
