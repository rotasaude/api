# Impresso da consulta finalizada para assinatura e carimbo (ADR 0031; spec
# §4; até o 19b não há assinatura digital). Gerado na hora, nunca gravado. A
# fonte embutida (Helvetica/WinAnsi) não tem emoji nem símbolos como "≥": o
# texto passa por `safe`, que troca o que falta por "?" — o impresso nunca cai.
require "prawn"

# O aviso de m17n é ruído: `safe` já garante texto que a fonte aceita.
Prawn::Fonts::AFM.hide_m17n_warning = true

module Consultations
  module Print
    class NotPrintable < StandardError; end

    OUTCOMES = { "discharged" => "Alta", "referred" => "Encaminhado", "return" => "Retorno",
                 "left" => "Saiu sem atendimento" }.freeze
    VITALS = { "systolic" => "PA sistólica (mmHg)", "diastolic" => "PA diastólica (mmHg)", "heart_rate" => "FC (bpm)",
               "respiratory_rate" => "FR (irpm)", "temperature_c" => "Temperatura (°C)", "spo2" => "SpO2 (%)",
               "capillary_glucose" => "Glicemia capilar (mg/dL)", "weight_kg" => "Peso (kg)", "height_cm" => "Altura (cm)",
               "pain_score" => "Dor (0-10)" }.freeze
    SECTIONS = { "subjective" => "Subjetivo", "objective" => "Objetivo", "assessment" => "Avaliação", "plan" => "Plano" }.freeze

    module_function

    # footer: PDF que vai ao PAdES (rodapé em toda página, sem assinatura à
    # mão). report: impresso com a seção "Assinaturas" (19b). Sem os dois: o
    # impresso do 19a.
    def call(consultation, footer: nil, addenda: true, report: nil)
      patient = consultation.patient
      raise NotPrintable, "not_finalized" unless consultation.finalized?
      raise NotPrintable, "patient_name_missing" if patient.full_name.blank?

      pdf = document(footer)
      header(pdf, consultation)
      patient_block(pdf, patient)
      professional_block(pdf, consultation)
      record(pdf, consultation)
      addenda(pdf, consultation) if addenda
      signatures(pdf, report) if report
      signature(pdf) if footer.nil? && (report.nil? || report.hand_signature?)
      pdf.render
    end

    # ADR 0032: o adendo tem documento próprio (JSON canônico e PDF). As
    # mudanças estruturadas vêm de item_changes (`changes` é do ActiveModel::Dirty).
    def addendum(addendum, footer:)
      consultation = addendum.consultation
      patient = consultation.patient
      raise NotPrintable, "patient_name_missing" if patient.full_name.blank?

      pdf = document(footer)
      header(pdf, consultation)
      pdf.move_down 6
      pdf.text safe("Adendo à consulta de #{consultation.finalized_at.in_time_zone.strftime('%d/%m/%Y %H:%M')}"),
               style: :bold, size: 12
      line(pdf, "Registrado em", addendum.created_at.in_time_zone.strftime("%d/%m/%Y %H:%M"))
      patient_block(pdf, patient)
      title(pdf, "Profissional")
      line(pdf, "Nome", addendum.author_user.professional&.professional_name || addendum.author_user.email_address)
      title(pdf, "Motivo")
      pdf.text safe(addendum.reason)
      title(pdf, "Texto")
      pdf.text safe(addendum.text)
      changes = addendum.item_changes.to_h
      if changes.present?
        title(pdf, "Mudanças estruturadas")
        change_lines(changes).each { |text| pdf.text safe(text) }
      end
      pdf.render
    end

    def safe(text)
      text.to_s.gsub(/\r\n?/, "\n").encode("Windows-1252", invalid: :replace, undef: :replace, replace: "?").encode("UTF-8")
    end

    def line(pdf, label, value) = pdf.text(safe("#{label}: #{value}"))

    def title(pdf, text)
      pdf.move_down 8
      pdf.text safe(text), style: :bold, size: 11
    end

    def header(pdf, c)
      unit = c.attendance.health_unit
      pdf.text safe(CityProfile.current&.name.to_s), style: :bold, size: 12
      pdf.text safe("#{unit.name}#{unit.cnes ? " — CNES #{unit.cnes}" : ''}")
      pdf.text safe("Registro de atendimento individual — consulta"), size: 12, style: :bold
      line(pdf, "Atendimento", "#{c.started_at.in_time_zone.strftime('%d/%m/%Y %H:%M')} a #{c.finalized_at.in_time_zone.strftime('%H:%M')}")
      line(pdf, "Tipo", Ledi::ConsultationMapping.care_type_label(c.care_type))
    end

    def patient_block(pdf, patient)
      title(pdf, "Paciente")
      line(pdf, "Nome", patient.display_name)
      line(pdf, "CPF", patient.cpf.to_s.sub(/\A(\d{3})(\d{3})(\d{3})(\d{2})\z/, '\1.\2.\3-\4'))
      birth = patient.birth_date.present? ? Date.iso8601(patient.birth_date).strftime("%d/%m/%Y") : "não informado"
      line(pdf, "Nascimento", birth)
    end

    def professional_block(pdf, c)
      professional = c.author_user.professional
      title(pdf, "Profissional")
      line(pdf, "Nome", professional&.professional_name || c.author_user.email_address)
      line(pdf, "Conselho", professional && "#{professional.council}-#{professional.council_state} #{professional.registration_number}")
      line(pdf, "CBO", "#{c.cbo_code} #{Professionals::Cbo.find(c.cbo_code)&.title}")
    end

    def record(pdf, c)
      SECTIONS.each do |field, label|
        title(pdf, label)
        pdf.text safe(c.public_send(field).presence || "—")
      end
      vitals = c.vitals.except("glucose_moment")
      if vitals.any?
        title(pdf, "Sinais vitais")
        vitals.each { |column, value| line(pdf, VITALS.fetch(column), value.is_a?(BigDecimal) ? value.to_s("F") : value) }
      end
      effective = Effective.call(c)
      title(pdf, "Problemas avaliados")
      effective[:problems].each do |row|
        label = ClinicalTerms.label(row.terminology, row.code, row.terminology_release_id)
        pdf.text safe("#{row.terminology.upcase} #{row.code} #{label} — #{row.status_after == 'active' ? 'ativo' : 'resolvido'}")
      end
      title(pdf, "Condutas")
      effective[:conducts].each { |code| pdf.text safe(Ledi::ConsultationMapping.conduct_label(code)) }
      if effective[:exam_requests].any?
        title(pdf, "Exames solicitados")
        effective[:exam_requests].each do |exam|
          pdf.text safe("#{exam.sigtap_code} #{ClinicalTerms::SigtapExams.label(exam.sigtap_code, exam.sigtap_competence)}" \
                        "#{exam.cid10_justification ? " (CID-10 #{exam.cid10_justification})" : ''}")
        end
      end
      outcome(pdf, c.attendance)
    end

    def outcome(pdf, attendance)
      title(pdf, "Desfecho")
      text = OUTCOMES.fetch(attendance.outcome.to_s, attendance.outcome.to_s)
      text += " — #{attendance.referral_unit.name}" if attendance.referral_unit
      text += " — #{attendance.referral_note}" if attendance.referral_note.present?
      pdf.text safe(text)
    end

    def addenda(pdf, c)
      rows = c.addenda.order(:created_at, :id).to_a
      return if rows.empty?

      title(pdf, "Adendos")
      rows.each do |a|
        author = a.author_user.professional&.professional_name || a.author_user.email_address
        pdf.text safe("#{a.created_at.in_time_zone.strftime('%d/%m/%Y %H:%M')} — #{author} — motivo: #{a.reason}"), style: :bold
        pdf.text safe(a.text)
      end
    end

    def signature(pdf)
      pdf.move_down 40
      pdf.stroke_horizontal_line 0, 250
      pdf.move_down 4
      pdf.text safe("Assinatura e carimbo do profissional")
      pdf.move_down 8
      pdf.text safe("Impresso em #{Time.current.strftime('%d/%m/%Y %H:%M')}. Sem assinatura digital: vale com a assinatura manual."),
               size: 8
    end
    def document(footer)
      pdf = Prawn::Document.new(page_size: "A4", margin: footer ? [ 40, 40, 80, 40 ] : 40,
                                info: { Title: "Registro de consulta", Producer: "Rota Saúde" })
      pdf.font_size(10)
      stamp_footer(pdf, footer) if footer
      pdf
    end

    # NGS2.06.05: o rodapé sai em toda página (repeater do Prawn, aplicado na
    # renderização a todas as páginas, inclusive as criadas depois). O bloco
    # roda já aqui (criação do stamp), e canvas + bounding_box de altura fixa
    # deixam o cursor no fundo da caixa, abaixo da margem: sem o `float`, o
    # primeiro texto abria uma 2ª página e a 1ª ficava só com o rodapé (api#55).
    def stamp_footer(pdf, footer)
      width = pdf.bounds.width
      text = safe(footer.text)
      pdf.repeat(:all) do
        pdf.float do
          pdf.canvas do
            pdf.bounding_box([ 40, 70 ], width: width, height: 56) do
              pdf.stroke_horizontal_rule
              pdf.move_down 4
              pdf.text text, size: 7
            end
          end
        end
      end
    end

    def signatures(pdf, report)
      title(pdf, "Assinaturas")
      report.lines.each { |text| pdf.text safe(text) }
    end

    # item_changes: chave presente = mudou; conducts/exam_requests são listas
    # finais (exam_requests [] = todos cancelados).
    def change_lines(changes)
      lines = []
      if changes.key?("evaluated_problems")
        lines << "Problemas avaliados:"
        Array(changes["evaluated_problems"]).each do |item|
          label = item["terminology"] && item["code"] ? ClinicalTerms.label(item["terminology"], item["code"], item["release_id"]) : nil
          lines << "  #{[ item['terminology']&.upcase, item['code'], label ].compact.join(' ')} — #{item['action']}"
        end
      end
      if changes.key?("conducts")
        lines << "Condutas (lista final):"
        Array(changes["conducts"]).each { |code| lines << "  #{Ledi::ConsultationMapping.conduct_label(code.to_i)}" }
      end
      if changes.key?("exam_requests")
        exams = Array(changes["exam_requests"])
        lines << (exams.empty? ? "Exames solicitados (lista final): nenhum (todos cancelados)" : "Exames solicitados (lista final):")
        exams.each do |item|
          label = ClinicalTerms::SigtapExams.label(item["sigtap_code"], item["sigtap_competence"])
          lines << "  #{item['sigtap_code']} #{label}#{item['cid10_justification'].present? ? " (CID-10 #{item['cid10_justification']})" : ''}"
        end
      end
      lines
    end
    private_class_method :document, :stamp_footer, :signatures, :change_lines, :line, :title, :header, :patient_block, :professional_block, :record, :outcome, :addenda, :signature
  end
end
