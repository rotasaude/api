# Linhas do arquivo a partir dos procedimentos faturáveis de uma competência,
# com o cadastro do momento (congelado no arquivo). BPA-C agregado por
# CBO × procedimento × idade × mês de realização; BPA-I item a item, com
# raça/cor, etnia e endereço do cadastro do paciente (D-U1; o fechamento só
# chega aqui com eles completos); IBGE de residência = os 6 primeiros
# dígitos do IBGE da cidade (spec §6); telefone (e bairro, se o paciente não
# tem) do par do wpda. Número vazio vira SN (§13 E4).
module Billing
  module Lines
    module_function

    def build(period:, establishment:, procedures:, settings:)
      ibge = CityProfile.current&.ibge_code.to_s[0, 6].presence
      c_lines = procedures.select { |p| p.instrument == "bpa_c" }
                          .group_by { |p| [ p.cbo_code, p.sigtap_code, age(p), p.performed_on.strftime("%Y%m") ] }
                          .map do |(cbo, code, years, month), list|
        BpaFile::CLine.new(cnes: establishment.cnes, competence: month, cbo: cbo, procedure: code, age: years, quantity: list.sum(&:quantity))
      end
      individual = procedures.select { |p| p.instrument == "bpa_i" }
      contacts = PatientContact.for(individual.map(&:patient_id).uniq)
      i_lines = individual.map do |p|
        contact = contacts[p.patient_id]
        BpaFile::ILine.new(key: p.id, cnes: establishment.cnes, competence: p.performed_on.strftime("%Y%m"),
                           professional_cns: Staff.cns(p.professional_user), cbo: p.cbo_code, performed_on: p.performed_on,
                           procedure: p.sigtap_code, sex: Critic::SEX.fetch(p.patient.sex), ibge: ibge, cid10: p.cid10, age: age(p),
                           quantity: p.quantity, character: BpaFile::CHARACTER.fetch(p.character), name: p.patient.full_name,
                           birth_date: Date.iso8601(p.patient.birth_date), race_color: p.patient.race_color,
                           ethnicity: p.patient.race_color == "05" ? p.patient.ethnicity : nil, zip: p.patient.address_zip,
                           street: p.patient.address_street, number: p.patient.address_number.presence || Patients::Demographics::NO_NUMBER,
                           complement: p.patient.address_complement,
                           district: p.patient.address_district.presence || contact&.district, phone: contact&.phone, cpf: p.patient.cpf)
      end
      header = BpaFile::Header.new(competence: period.competence, origin_name: settings.origin_name, origin_acronym: settings.origin_acronym,
                                   origin_cnpj: settings.origin_cnpj, destination_body: settings.destination_body,
                                   management: settings.management)
      BpaFile.build(header: header, c_lines: c_lines, i_lines: i_lines)
    end

    def age(procedure) = Citizen.age_between(Date.iso8601(procedure.patient.birth_date), procedure.performed_on)
    private_class_method :age
  end
end
