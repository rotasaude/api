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
    QR_SIZE = 84

    module_function

    def call(document, footer: nil)
      raise NotPrintable, "cancelled" if document.cancelled?

      content = document.content_data
      labels = document.prescription? && content["copies"] == 2 ? COPIES : [ nil ]
      pdf = Consultations::Print.document(footer, title: "Documento clínico")
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
      title = document.prescription? && content["antimicrobial"] ? ANTIMICROBIAL_TITLE : TITLES.fetch(document.kind)
      pdf.text s(title), style: :bold, size: 13
      pdf.text s(label), style: :bold if label
      pdf.text s("Emitido em #{document.issued_at.in_time_zone.strftime('%d/%m/%Y %H:%M')}"), size: 9
    end

    def person(pdf, document)
      person = document.patient || document.citizen
      pdf.move_down 8
      pdf.text s("Paciente: #{person.display_name}"), style: :bold
      birth = person.birth_date.present? ? date(person.birth_date) : "não informado"
      # O impresso é do paciente: CPF completo, como o impresso da consulta do 19a.
      pdf.text s("CPF: #{person.cpf.to_s.sub(/\A(\d{3})(\d{3})(\d{3})(\d{2})\z/, '\1.\2.\3-\4')} — Nascimento: #{birth}")
      pdf.text s("Endereço: ________________________________________________") if document.prescription?
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
      when_text = content["period"] ? PERIODS.fetch(content["period"]) : "das #{content['arrived_at']}#{content['left_at'] ? " às #{content['left_at']}" : ''}"
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
                    item["duration_days"] && "por #{item['duration_days']} dia(s)", item["continuous"] && "uso contínuo" ].compact
        pdf.indent(14) { pdf.text s(details.join(". ")) }
        pdf.move_down 4
      end
      pdf.text s("Validade: até #{date(content['valid_until'])}#{content['antimicrobial'] ? ' (10 dias — antimicrobiano)' : ''}") if content["valid_until"]
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
      pdf.text s(Screenings::Json.staff_name(author)), style: :bold
      pdf.text s(council) if council
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
    end
    private_class_method :copy, :s, :date, :header, :person, :sick_note_body, :attendance_declaration_body,
                         :prescription_body, :exam_requisition_body, :note, :professional, :hand_signature, :verification
  end
end
