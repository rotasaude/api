# app/services/clinical_documents/content/patient_identification.rb
# Identificação do paciente na RCE (ADR 0034; spec §5; contrato §12, decisão do
# usuário, 2026-10-10): o CPF é SEMPRE o do cadastro do paciente, preenchido
# aqui (CPF, `no_cpf` e passaporte da entrada são ignorados; o 19d não tem "não
# possui"), e o endereço completo, digitado na receita. Na RET é opcional
# (P&R 23): quando vem, vem inteira. Erros com o campo exato; nunca o valor.
module ClinicalDocuments
  module Content
    module PatientIdentification
      ROOT = "patient_identification".freeze

      module_function

      def call(value, required:, patient:)
        if value.nil?
          return required ? missing(ROOT) : Result.ok(value: nil)
        end
        return invalid(ROOT) unless value.is_a?(Hash)

        value = value.to_h.transform_keys(&:to_s)
        cpf = CitizenIdentity::Cpf.normalize(patient&.cpf.to_s)
        return missing("#{ROOT}.cpf") unless cpf
        return missing("#{ROOT}.address") if value["address"].nil?

        address, field = Address.normalize(value["address"])
        return invalid(field == "address" ? "#{ROOT}.address" : "#{ROOT}.address.#{field}") unless address

        Result.ok(value: { "cpf" => cpf, "address" => address })
      end

      def missing(field) = Result.fail(:patient_identification_required, details: { field: field })
      def invalid(field) = Result.fail(:invalid_content, details: { field: field })
      private_class_method :missing, :invalid
    end
  end
end
