# Bairro e telefone do par validado mais recente do paciente (spec §2
# decisão 8: o que o wpda tem; o endereço do BPA-I é o do paciente, D-U1). Telefone sem o
# 55, só com 10 ou 11 dígitos; senão, nada.
module Billing
  module PatientContact
    Contact = Data.define(:district, :phone) do
      # LGPD: bairro e telefone nunca em inspect/log.
      def inspect = "#<#{self.class.name} district_set=#{district.present?} phone_set=#{phone.present?}>"
      alias_method :to_s, :inspect
      def pretty_print(q) = q.text(inspect) # Data#pretty_print ignora o inspect
    end

    module_function

    def for(patient_ids)
      Citizen.not_erased.verification_level_verified.where(patient_id: patient_ids).includes(:neighborhood)
             .order(:updated_at, :id).to_a.group_by(&:patient_id).transform_values { |list| contact(list.last) }
    end

    def contact(citizen)
      digits = citizen.phone.to_s.gsub(/\D/, "")
      digits = digits.delete_prefix("55") if digits.length > 11
      Contact.new(district: citizen.neighborhood&.name, phone: digits.match?(/\A\d{10,11}\z/) ? digits : nil)
    end
    private_class_method :contact
  end
end
