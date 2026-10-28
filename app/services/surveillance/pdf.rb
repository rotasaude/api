# Ficha de notificação individual no formato do Sinan, para digitação (módulo
# 25; contrato §7, §14; K10): os blocos e os números de campo da NINDIV (1–30
# mais o notificador), cada campo com o número e o rótulo da ficha; códigos do
# Sinan E a descrição ("4 — Parda"). Gerada na hora, nunca gravada. A folha, a
# fonte e o rodapé em toda página são os de Consultations::Print.document; o
# texto passa por Print.safe (a fonte embutida não tem todo símbolo).
# Texto longo quebra de linha (Prawn), nunca sai da página. Do notificador sai
# o nome profissional e a função (CBO), nunca CPF nem e-mail. Nada vai a log.
require "prawn"

module Surveillance
  module Pdf
    TITLE = "Ficha de Notificação Individual (Sinan) — para digitação".freeze
    FOOTER_TEXT = "Gerado pelo Rota Saúde — não substitui o registro no Sinan".freeze
    # Consultations::Print.document só lê `footer.text`.
    Footer = Data.define(:text)
    SEX = { "M" => "Masculino", "F" => "Feminino", "I" => "Ignorado" }.freeze
    NONE = "—".freeze
    CLASSIFICATION = { "confirmed" => "Confirmado", "discarded" => "Descartado", "inconclusive" => "Inconclusivo" }.freeze

    module_function

    # notification: DiseaseNotification -> String (bytes do PDF).
    def call(notification)
      n = notification
      form = n.form.to_h
      pdf = Consultations::Print.document(Footer.new(FOOTER_TEXT), title: "Ficha de Notificação Individual (Sinan)")
      header(pdf)
      general(pdf, n)
      person(pdf, n, form)
      residence(pdf, n, form)
      notifier(pdf, n)
      pdf.number_pages "Página <page> de <total>", at: [ 0, -14 ], width: pdf.bounds.width, size: 7, align: :right
      pdf.render
    end

    def s(text) = Consultations::Print.safe(text)
    def date(value) = value&.strftime("%d/%m/%Y")

    def header(pdf)
      pdf.text s(CityProfile.current&.name.to_s), style: :bold, size: 12
      pdf.text s(TITLE), style: :bold, size: 13
    end

    def section(pdf, text)
      pdf.move_down 8
      pdf.text s(text), style: :bold, size: 11
      pdf.move_down 2
    end

    # número (ou nil) + rótulo em negrito, valor em seguida; vazio vira "—".
    def field(pdf, number, label, value)
      head = number ? "#{number} #{label}: " : "#{label}: "
      pdf.formatted_text [ { text: s(head), styles: [ :bold ] }, { text: s(value.presence || NONE) } ]
    end

    # Campo de código do Sinan (chave de config/surveillance/sinan-form.yml): "4 — Parda".
    def form_field(pdf, form, key, label)
      spec = Form.fields.fetch(key)
      raw = form[key]
      value = case spec.fetch("type")
      when "code" then raw.present? ? "#{raw} — #{spec.fetch('domain').fetch(raw, raw)}" : nil
      else raw
      end
      field(pdf, spec.fetch("field"), label, value)
    end

    def general(pdf, n)
      disease = Diseases.all.index_by(&:code)
      found = disease[n.disease_code]
      cid = Array(found&.cid10).join(", ")
      profile = CityProfile.current
      section(pdf, "Dados gerais")
      field(pdf, 1, "Tipo de notificação", "2 — Individual")
      field(pdf, 2, "Agravo/doença", [ Json.disease(n, disease).fetch(:name), (cid.present? ? "CID-10 #{cid}" : nil) ].compact.join(" — "))
      field(pdf, 3, "Data da notificação", date(n.suspected_on))
      field(pdf, 4, "UF", profile&.uf)
      field(pdf, 5, "Município de notificação", municipality(profile))
      field(pdf, 6, "Unidade de saúde (notificadora)", [ n.health_unit.name, (n.unit_cnes ? "CNES #{n.unit_cnes}" : nil) ].compact.join(" — "))
      field(pdf, 7, "Data dos primeiros sintomas", date(n.symptoms_on))
      field(pdf, nil, "Situação", situation(n))
    end

    # Situação da notificação no Rota Saúde, em português (não é campo do Sinan).
    def situation(n)
      case n.status
      when "possible" then "Possível notificação não feita — confirmar antes de digitar"
      when "notified" then "Notificada"
      when "investigating" then "Em investigação"
      when "closed" then "Encerrada (#{CLASSIFICATION.fetch(n.classification.to_s, n.classification)})"
      when "entered" then "Digitada no Sinan (nº #{n.official_number})"
      when "dismissed" then "Descartada pela vigilância — NÃO digitar no Sinan"
      else n.status
      end
    end

    def person(pdf, n, form)
      patient = n.patient
      birth = birth_date(patient)
      section(pdf, "Notificação individual")
      field(pdf, 8, "Nome do paciente", patient.full_name)
      field(pdf, nil, "Nome social", patient.social_name) if patient.social_name.present?
      field(pdf, 9, "Data de nascimento", date(birth))
      field(pdf, 10, "Idade (na data da notificação)", age(birth, n.suspected_on))
      field(pdf, 11, "Sexo", sex(patient))
      form_field(pdf, form, "pregnancy", "Gestante")
      field(pdf, 13, "Raça/Cor", race(patient, form))
      form_field(pdf, form, "schooling", "Escolaridade")
      field(pdf, 15, "Nº do Cartão SUS", patient.cns)
      field(pdf, 16, "Nome da mãe", patient.mother_name)
    end

    def residence(pdf, n, form)
      profile = CityProfile.current
      section(pdf, "Dados de residência")
      field(pdf, 17, "UF", form["residence_uf"])
      field(pdf, 18, "Município de residência", n.resident_elsewhere ? "IBGE #{n.residence_ibge}" : municipality(profile))
      field(pdf, 19, "Distrito", form["residence_district"])
      field(pdf, 20, "Bairro", form["residence_neighborhood"].presence || n.neighborhood&.name)
      field(pdf, 21, "Logradouro (rua, avenida, ...)", form["residence_street"])
      field(pdf, 22, "Número", form["residence_number"])
      field(pdf, 23, "Complemento", form["residence_complement"])
      field(pdf, 24, "Geo campo 1", form["residence_geo1"])
      field(pdf, 25, "Geo campo 2", form["residence_geo2"])
      field(pdf, 26, "Ponto de referência", form["residence_reference"])
      field(pdf, 27, "CEP", zip(form["residence_zip"]))
      field(pdf, 28, "(DDD) Telefone", phone(form["phone"]))
      form_field(pdf, form, "residence_zone", "Zona")
      field(pdf, 30, "País (se residente fora do Brasil)", form["residence_country"])
      field(pdf, nil, "Ocupação (CBO)", occupation(form["occupation_cbo"]))
    end

    # Nome profissional e função; sem perfil profissional, "não informado"
    # (nunca o e-mail do usuário).
    def notifier(pdf, n)
      user = n.notifier_user
      section(pdf, "Notificador")
      field(pdf, nil, "Nome", user&.professional&.professional_name || "não informado")
      field(pdf, nil, "Função", notifier_role(n, user))
    end

    # CBO da consulta de origem; senão o do vínculo ativo na unidade.
    def notifier_role(n, user)
      return nil unless user&.professional

      code = n.consultation&.cbo_code || user.professional.links.active.find_by(health_unit_id: n.health_unit_id)&.cbo_code
      return nil if code.blank?

      [ code, Professionals::Cbo.find(code)&.title ].compact.join(" ")
    end

    def municipality(profile)
      return nil unless profile

      [ profile.name, (profile.ibge_code ? "IBGE #{profile.ibge_code}" : nil) ].compact.join(" — ")
    end

    def birth_date(patient)
      Date.iso8601(patient.birth_date.to_s)
    rescue Date::Error
      nil
    end

    # Raça/cor da ficha (já em código do Sinan) ou, na falta, a do paciente convertida.
    def race(patient, form)
      code = form["race_color"].presence || Catalog::RACE_TO_SINAN.fetch(patient.race_color.to_s, "9")
      "#{code} — #{Form.fields.dig('race_color', 'domain').fetch(code, code)}"
    end

    def sex(patient)
      code = Catalog::SEX_TO_SINAN.fetch(patient.sex.to_s, "I")
      "#{code} — #{SEX.fetch(code)}"
    end

    # Idade na data da notificação: anos; menor de 1 ano, meses; menor de 1 mês, dias.
    def age(birth, on)
      return nil if birth.nil? || birth > on

      years = Citizen.age_between(birth, on)
      return "#{years} #{years == 1 ? 'ano' : 'anos'}" if years >= 1

      months = (on.year * 12 + on.month) - (birth.year * 12 + birth.month)
      months -= 1 if on.day < birth.day
      return "#{months} #{months == 1 ? 'mês' : 'meses'}" if months >= 1

      days = (on - birth).to_i
      "#{days} #{days == 1 ? 'dia' : 'dias'}"
    end

    def zip(value) = value.to_s.sub(/\A(\d{5})(\d{3})\z/, '\1-\2').presence
    def phone(value) = value.to_s.sub(/\A(\d{2})(\d{4,5})(\d{4})\z/, '(\1) \2-\3').presence

    def occupation(code)
      return nil if code.blank?

      [ code, Professionals::Cbo.find(code)&.title ].compact.join(" ")
    end
    private_class_method :header, :section, :field, :form_field, :general, :person, :residence, :notifier, :notifier_role,
                         :municipality, :birth_date, :race, :sex, :age, :zip, :phone, :occupation, :s, :date
  end
end
