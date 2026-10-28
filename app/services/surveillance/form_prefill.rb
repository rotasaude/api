# A ficha nasce pré-preenchida (módulo 25, Desvio 8; contrato §14): raça/cor
# do paciente convertida para o Sinan ("9" sem raça), endereço do paciente
# (o 24a o regrava do domicílio; a UF é a da cidade), telefone do par
# validado mais recente (só dígitos, sem o 55) e a ocupação da última versão
# do cadastro individual ativo. Zona, país e o resto ficam vazios (chave
# ausente). Só chaves de Surveillance::Form. Nunca em log.
module Surveillance
  module FormPrefill
    # Chave da ocupação na seção sociodemográfica do 24a (config/ledi/registration_dictionaries.yml).
    OCCUPATION_KEY = "ocupacao_codigo_cbo2002".freeze
    ADDRESS = { "residence_zip" => :address_zip, "residence_street" => :address_street, "residence_number" => :address_number,
                "residence_complement" => :address_complement, "residence_neighborhood" => :address_district }.freeze

    module_function

    def for(patient)
      address = ADDRESS.transform_values { |column| patient.public_send(column).presence }.compact
      values = { "race_color" => Catalog::RACE_TO_SINAN.fetch(patient.race_color.to_s, "9"),
                 "residence_uf" => (CityProfile.current&.uf if address.any?),
                 "phone" => Billing::PatientContact.for([ patient.id ])[patient.id]&.phone,
                 "occupation_cbo" => occupation(patient) }.merge(address)
      values.compact.slice(*Form.keys)
    end

    def occupation(patient)
      version = IndividualRegistration.active_registrations.find_by(patient_id: patient.id)&.latest_version
      version&.sociodemographic.to_h[OCCUPATION_KEY].presence&.to_s
    end
    private_class_method :occupation
  end
end
