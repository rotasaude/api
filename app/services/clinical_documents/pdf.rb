# app/services/clinical_documents/pdf.rb
# PDF do documento clínico (ADR 0033; spec §6), gerado na hora e nunca
# gravado (o assinado mora em signatures). Cabeçalho (cidade, unidade, CNES,
# endereço), corpo do tipo, profissional (conselho, CBO), e em TODA via o QR
# code do endereço de conferência e o código curto. Papel: espaço para
# assinatura e carimbo. Digital (footer): rodapé NGS2 em toda página (e o
# aviso de simulada), sem espaço à mão. Antimicrobiano: 1ª via farmácia, 2ª
# via paciente. A fonte embutida (WinAnsi) não tem emoji nem "≥":
# Consultations::Print.safe troca o que falta por "?". A folha (A4, margem
# do rodapé, repeater NGS2) é a de Consultations::Print.document.
# RCE/RET (ADR 0034): título da Anvisa, número SNCR em destaque, endereços,
# rodapé Anvisa e faixa de simulado. O número só sai no documento digital: o
# que voltou ao papel (ou nasceu nele) não o imprime, mesmo com `sncr` no content.
require "prawn"

module ClinicalDocuments
  module Pdf
    class NotPrintable < StandardError; end

    TITLES = { "sick_note" => "ATESTADO", "attendance_declaration" => "DECLARAÇÃO DE COMPARECIMENTO",
               "prescription" => "RECEITUÁRIO", "exam_requisition" => "REQUISIÇÃO DE EXAMES" }.freeze
    ANTIMICROBIAL_TITLE = "RECEITUÁRIO DE ANTIMICROBIANO — RETENÇÃO DA 2ª VIA".freeze
    COPIES = [ "1ª via — farmácia", "2ª via — paciente" ].freeze
    ROUTES = { "oral" => "via oral", "sublingual" => "via sublingual", "topical" => "uso tópico", "ophthalmic" => "uso oftálmico",
               "otic" => "uso otológico", "nasal" => "uso nasal", "inhalation" => "via inalatória", "vaginal" => "via vaginal",
               "rectal" => "via retal", "intramuscular" => "via intramuscular", "intravenous" => "via intravenosa",
               "subcutaneous" => "via subcutânea", "other" => "outra via" }.freeze
    COMPANION_REASONS = { "clt_473_x" => "acompanhar consulta ou exame de gestante (CLT, art. 473, X)",
                          "clt_473_xi" => "acompanhar filho de até 6 anos em consulta (CLT, art. 473, XI)",
                          "clt_473_xii" => "realizar exames preventivos de câncer (CLT, art. 473, XII)",
                          "other" => "acompanhar o paciente" }.freeze
    PERIODS = { "morning" => "no período da manhã", "afternoon" => "no período da tarde", "full_day" => "em período integral" }.freeze
    # ADR 0034 (Desvio 14; P&R RDC 1.000 itens 7 e 67; modelos eletrônicos da Anvisa).
    SPECIAL_TITLE = "RECEITA DE CONTROLE ESPECIAL".freeze
    RET_TITLE = "RECEITA DE ANTIMICROBIANO".freeze
    ELECTRONIC = " — ELETRÔNICA".freeze
    SIMULATED_BAND = "NUMERAÇÃO SIMULADA — SEM VALIDADE".freeze
    ANVISA_LINE = "Verifique a numeração e registre a utilização desta prescrição em sncr.anvisa.gov.br".freeze
    PLATFORM_NAME = "Rota Saúde".freeze
    QR_SIZE = 84
    RECEPTION_ISSUER = "Emitido pela recepção".freeze

    module_function

    def call(document, footer: nil)
      raise NotPrintable, "cancelled" if document.cancelled?

      content = document.content_data
      labels = document.prescription? && content["copies"] == 2 ? COPIES : [ nil ]
      pdf = Consultations::Print.document(footer, title: "Documento clínico")
      simulated_band(pdf) if sncr_shown?(document, content) && content.dig("sncr", "simulated")
      labels.each_with_index do |label, index|
        pdf.start_new_page if index.positive?
        copy(pdf, document, content, label, footer)
      end
      pdf.render
    end

    def copy(pdf, document, content, label, footer)
      header(pdf, document, content, label)
      person(pdf, document)
      send(:"#{document.kind}_body", pdf, document, content)
      professional(pdf, document, content)
      hand_signature(pdf) unless footer
      verification(pdf, document)
    end

    def s(text) = Consultations::Print.safe(text)
    def date(iso) = Date.iso8601(iso).strftime("%d/%m/%Y")

    def header(pdf, document, content, label)
      unit = document.attendance.health_unit
      pdf.text s(CityProfile.current&.name.to_s), style: :bold, size: 12
      pdf.text s("#{unit.name}#{unit.cnes ? " — CNES #{unit.cnes}" : ''}")
      address = [ unit.address_street, unit.address_number, unit.address_complement ].compact_blank.join(", ")
      pdf.text s("#{address}#{unit.address_zip ? " — CEP #{unit.address_zip}" : ''}") if address.present?
      pdf.move_down 8
      pdf.text s(title(document, content)), style: :bold, size: 13
      pdf.text s("Nº #{content.dig('sncr', 'number')}"), style: :bold, size: 16 if sncr_shown?(document, content)
      pdf.text s(label), style: :bold if label
      pdf.text s("Emitido em #{document.issued_at.in_time_zone.strftime('%d/%m/%Y %H:%M')}"), size: 9
    end

    def person(pdf, document)
      person = document.patient || document.citizen
      identification = document.prescription? ? document.content_data["patient_identification"] : nil
      birth = person.birth_date.present? ? date(person.birth_date) : "não informado"
      pdf.move_down 8
      pdf.text s("Paciente: #{person.display_name}"), style: :bold
      if identification
        # O CPF da identificação é o do cadastro (preenchido pelo api na emissão).
        pdf.text s("CPF: #{cpf(identification['cpf'] || person.cpf)} — Nascimento: #{birth}")
        pdf.text s("Endereço: #{Address.line(identification['address'])}") if identification["address"]
      else
        # O impresso é do paciente: CPF completo, como o impresso da consulta do 19a.
        pdf.text s("CPF: #{cpf(person.cpf)} — Nascimento: #{birth}")
        pdf.text s("Endereço: ________________________________________________") if blank_address_line?(document)
      end
    end

    # A RET digital (com número) não pede endereço do paciente (RDC 1.000): sem
    # identificação, nada de linha em branco; a RET de papel continua com ela.
    def blank_address_line?(document)
      return false unless document.prescription?

      content = document.content_data
      !(content["category"] == "antimicrobial" && sncr_shown?(document, content))
    end

    def cpf(value) = value.to_s.sub(/\A(\d{3})(\d{3})(\d{3})(\d{2})\z/, '\1.\2.\3-\4')
    def phone(value) = value.to_s.sub(/\A(\d{2})(\d{4,5})(\d{4})\z/, '(\1) \2-\3')

    def title(document, content)
      return TITLES.fetch(document.kind) unless document.prescription?

      case content["category"]
      when "special_control" then document.digital? ? "#{SPECIAL_TITLE}#{ELECTRONIC}" : SPECIAL_TITLE
      when "antimicrobial" then document.digital? ? "#{RET_TITLE}#{ELECTRONIC}" : ANTIMICROBIAL_TITLE
      else content["antimicrobial"] ? ANTIMICROBIAL_TITLE : TITLES.fetch("prescription")
      end
    end

    # O número só sai no documento digital (a volta ao papel anula o número).
    def sncr_shown?(document, content) = document.digital? && content["sncr"].is_a?(Hash)

    # Faixa na margem de cima de toda página (a margem de 40 pt a comporta).
    def simulated_band(pdf)
      pdf.repeat(:all) do
        pdf.bounding_box([ 0, pdf.bounds.top + 28 ], width: pdf.bounds.width, height: 18) do
          pdf.fill_color "B00020"
          pdf.text s(SIMULATED_BAND), style: :bold, size: 11, align: :center
          pdf.fill_color "000000"
        end
      end
    end

    # O CNPJ é o do modo em que o número saiu (o do documento), não o modo
    # corrente da cidade.
    def anvisa_footer(pdf, document)
      settings = document.content_data.dig("sncr", "simulated") ? Sncr::Config.simulated : Sncr::Config.real
      cnpj = settings&.cnpj
      pdf.move_down 6
      pdf.text s("Plataforma de prescrição: #{PLATFORM_NAME}#{cnpj ? " — CNPJ #{Cnpj.display(cnpj)}" : ''}"), size: 8
      pdf.text s("Esta prescrição pode ser verificada em: #{document.verification_url}"), size: 8
      pdf.text s("Assinatura digital ICP-Brasil: valide em validar.iti.gov.br"), size: 8
      pdf.text s(ANVISA_LINE), size: 8
    end

    def sick_note_body(pdf, document, content)
      pdf.move_down 10
      if content["type"] == "leave"
        pdf.text s("Atesto, para os devidos fins, que o(a) paciente acima foi atendido(a) nesta unidade e necessita de " \
                   "afastamento de suas atividades por #{content['days']} dia(s), a partir de #{date(content['start_on'])}.")
        if content["cid10"]
          pdf.move_down 6
          pdf.text s("CID-10: #{content.dig('cid10', 'code')} — #{content.dig('cid10', 'label')} " \
                     "(informado com autorização expressa do paciente).")
        end
      else
        reason = COMPANION_REASONS.fetch(content["companion_reason"])
        # Data do acompanhamento: o start_on informado; sem ele, a da emissão.
        on = content["start_on"] ? date(content["start_on"]) : document.issued_at.in_time_zone.strftime("%d/%m/%Y")
        pdf.text s("Declaro, para os devidos fins, que #{content['companion_name']} (#{content['companion_kinship']}) " \
                   "esteve nesta unidade em #{on} para #{reason}.")
      end
      note(pdf, content)
    end

    def attendance_declaration_body(pdf, _document, content)
      when_text = if content["period"] then PERIODS.fetch(content["period"])
                  elsif content["left_at"] then "das #{content['arrived_at']} às #{content['left_at']}"
                  else "a partir das #{content['arrived_at']}" # atendimento ainda aberto: sem hora de saída
                  end
      pdf.move_down 10
      pdf.text s("Declaro, para os devidos fins, que o(a) paciente acima esteve nesta unidade de saúde (#{content['unit_name']}) " \
                 "em #{date(content['date'])}, #{when_text}" \
                 "#{content['companion_name'] ? ", acompanhado(a) de #{content['companion_name']}" : ''}.")
    end

    def prescription_body(pdf, _document, content)
      if (protocol = content["nursing_protocol"])
        pdf.move_down 6
        pdf.text s("Prescrição de enfermagem conforme o protocolo \"#{protocol['title']}\" nº #{protocol['number']}/#{protocol['year']}."), size: 9
        pdf.text s("Instituição: #{CityProfile.current&.name} — CNPJ #{Cnpj.display(content['city_cnpj'])}"), size: 9
      end
      pdf.move_down 8
      content["items"].each do |item|
        pdf.text s("#{item['position']}. #{item['printed_description']}#{item['free_text'] ? ' (registro manual)' : ''} — " \
                   "#{item['quantity']} #{item['quantity_unit']}"), style: :bold
        details = [ "Uso: #{ROUTES.fetch(item['route'])}", item["dosage_instructions"],
                    ("por #{item['duration_days']} dia(s)" if item["duration_days"]), ("uso contínuo" if item["continuous"]) ].compact
        pdf.indent(14) { pdf.text s(sentences(details)) }
        pdf.move_down 4
      end
      pdf.text s("Validade: até #{date(content['valid_until'])}#{content['antimicrobial'] ? ' (10 dias — antimicrobiano)' : ''}") if content["valid_until"]
    end

    # Junta as partes com ". ", sem ponto duplo quando a parte (texto livre da
    # posologia) já termina em pontuação.
    def sentences(parts)
      parts.each_with_index.map { |part, i| i == parts.size - 1 || part.match?(/[.!?;:…]\s*\z/) ? part : "#{part}." }.join(" ")
    end

    def exam_requisition_body(pdf, _document, content)
      pdf.move_down 8
      content["exams"].each do |exam|
        pdf.text s("#{exam['sigtap_code']} — #{exam['label']} (competência #{exam['competence']})" \
                   "#{exam['cid10_justification'] ? " — CID-10 #{exam['cid10_justification']}" : ''}")
      end
      note(pdf, content)
    end

    def note(pdf, content)
      return unless content["note"]

      pdf.move_down 6
      pdf.text s("Observação: #{content['note']}")
    end

    def professional(pdf, document, content)
      author = document.author_user
      council = Json.council(author.professional)
      pdf.move_down 14
      # Sem perfil profissional (recepção) não há nome: linha neutra e a
      # matrícula abaixo, nunca o e-mail de login (o papel vai ao cidadão).
      pdf.text s(author.professional&.professional_name || RECEPTION_ISSUER), style: :bold
      pdf.text s(council) if council
      if (contact = content["prescriber_contact"])
        pdf.text s("Endereço: #{Address.line(contact['address'])}")
        pdf.text s("Telefone: #{phone(contact['phone'])}")
      end
      pdf.text s("CBO #{document.cbo_code} #{Professionals::Cbo.find(document.cbo_code)&.title}") if document.cbo_code
      pdf.text s("Matrícula: #{content['issuer_registration']}") if content["issuer_registration"]
    end

    def hand_signature(pdf)
      pdf.move_down 30
      pdf.stroke_horizontal_line 0, 250
      pdf.move_down 4
      pdf.text s("Assinatura e carimbo")
    end

    def verification(pdf, document)
      pdf.start_new_page if pdf.cursor < QR_SIZE + 20
      pdf.move_down 12
      top = pdf.cursor
      Qr.draw(pdf, document.verification_url, at: [ 0, top ], size: QR_SIZE)
      pdf.bounding_box([ QR_SIZE + 10, top - 10 ], width: pdf.bounds.width - QR_SIZE - 10) do
        pdf.text s("Confira a autenticidade e a situação deste documento:"), size: 9
        pdf.text s(document.verification_url), size: 8
        pdf.text s("ou em #{CityPublicUrl.base(Current.city)}/v com o código #{Codes.display(document.short_code)} e o ano de nascimento do paciente."), size: 9
      end
      pdf.move_cursor_to(top - QR_SIZE) if pdf.cursor > top - QR_SIZE
      anvisa_footer(pdf, document) if sncr_shown?(document, document.content_data)
    end
    private_class_method :copy, :s, :date, :header, :person, :sick_note_body, :attendance_declaration_body,
                         :prescription_body, :exam_requisition_body, :note, :professional, :hand_signature, :verification,
                         :title, :sncr_shown?, :simulated_band, :anvisa_footer, :cpf, :phone, :blank_address_line?
  end
end
