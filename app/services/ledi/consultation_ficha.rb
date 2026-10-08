# A ficha da consulta (ADR 0031; spec §6). Nasce da consulta finalizada, só com
# a exportação utilizável (a regra do módulo 18), uma vez por consulta. Sem
# identificação completa: "não gerada" com motivos de lista fechada.
# Identificação como no 18: só o CPF; nascimento e sexo do PACIENTE. Adendo
# com mudança estruturada (refresh!): pendente/falhou → regrava o conteúdo
# com o mesmo uuid; recusada → linha nova com replaces_outbox_id; em envio →
# InFlight (o job tenta de novo); aceita → uma correction_pending por aceita,
# nunca enviada (api#41; trigger ledi_outbox_correction_guard).
module Ledi
  module ConsultationFicha
    SOURCE_TYPE = "Consultation".freeze
    AlreadyResolved = Ledi::ScreeningFicha::AlreadyResolved
    class InFlight < StandardError; end

    module_function

    def exportable?(city) = Ledi::ScreeningFicha.exportable?(city)

    def generate(consultation, city: Current.city)
      return :skipped unless consultation.finalized?
      return :unusable unless exportable?(city)
      return :exists if LediOutboxEntry.exists?(source_type: SOURCE_TYPE, source_id: consultation.id)

      ficha, reasons = build(consultation)
      return record_failure!(consultation, reasons) if reasons.any?

      resolve_failure!(consultation)
      Ledi::Enqueue.call(ficha, city: city) ? :enqueued : :unusable
    end

    # Sob o lock da linha, o status antes de tudo: em envio → InFlight (o job
    # tenta de novo), nunca "não gerada". Regravada/regerada/correção → a
    # "não gerada" aberta da consulta fica resolvida.
    def refresh!(consultation, city: Current.city)
      return :unusable unless exportable?(city)

      latest = latest_entry(consultation)
      return generate(consultation, city: city) unless latest

      ApplicationRecord.transaction do
        latest.lock!
        raise InFlight if latest.status == "sending"

        ficha, reasons = build(consultation)
        next record_failure!(consultation, reasons) if reasons.any?

        outcome = case latest.status
                  when "pending", "failed"
                    latest.update!(bytes: Ledi::Transport.wrap(ficha, city: city, uuid: latest.uuid))
                    :rewritten
                  when "rejected" then Ledi::Enqueue.call(ficha, city: city, replaces: latest) ? :regenerated : :unusable
                  when "accepted" then correction!(latest, ficha, city)
                  end
        resolve_failure!(consultation) unless outcome == :unusable
        outcome
      end
    end

    # A ficha da consulta (a mais recente; a correção de uma aceita não conta).
    def latest_entry(consultation)
      LediOutboxEntry.where(source_type: SOURCE_TYPE, source_id: consultation.id)
                     .where.not(status: "correction_pending").order(created_at: :desc, id: :desc).first
    end

    def build(consultation)
      attendance = consultation.attendance
      unit = attendance.health_unit
      professional = consultation.professional_link.professional
      patient = consultation.patient
      ine = Ledi::ScreeningFicha.team_ine(professional, unit)
      birth = birth_date(patient)
      effective = Consultations::Effective.call(consultation)

      reasons = []
      reasons << "unit_without_cnes" if unit.cnes.blank?
      reasons << "professional_without_team" if ine.nil?
      reasons << "professional_without_cns" unless Professionals::Cns.valid?(professional.cns)
      reasons << "citizen_without_birth_date" if birth.nil?
      reasons << "citizen_without_sex" unless Citizen::SEXES.include?(patient.sex)
      unknown = effective[:problems].any? do |row|
        row.terminology == "ciap2" && !Ciap2Code.exists?(release_id: row.terminology_release_id, code: row.code)
      end
      reasons << "unknown_ciap2" if unknown
      return [ nil, reasons ] if reasons.any?

      started = consultation.started_at
      identity = Ledi::Fichas::ScreeningIdentity.new(
        cnes: unit.cnes, ine: ine, professional_cns: professional.cns, cbo: consultation.cbo_code,
        citizen_cpf: patient.cpf, birth_date: birth, sex: patient.sex, started_at: started,
        ended_at: [ consultation.finalized_at, started ].max, ibge_code: CityProfile.current&.ibge_code
      )
      care = Ledi::Fichas::IndividualCare::Care.new(
        care_type: consultation.care_type, problems: effective[:problems].map { |row| problem(row, started) },
        conducts: effective[:conducts], exams: effective[:exam_requests].map(&:sigtap_code),
        measurements: measurements(consultation, attendance)
      )
      [ Ledi::Fichas::IndividualCare.new(identity: identity, care: care, source_id: consultation.id), [] ]
    end

    def record_failure!(consultation, reasons)
      failure = LediGenerationFailure.unresolved.find_by(source_type: SOURCE_TYPE, source_id: consultation.id)
      if failure
        failure.update!(reason_codes: reasons) unless failure.reason_codes == reasons
      else
        failure = ApplicationRecord.transaction(requires_new: true) do
          LediGenerationFailure.create!(source_type: SOURCE_TYPE, source_id: consultation.id, reason_codes: reasons)
        end
        DomainEvents.publish("ledi.generation_failed", failure_id: failure.id, source_type: SOURCE_TYPE,
                                                       source_id: consultation.id)
      end
      :failed
    rescue ActiveRecord::RecordNotUnique
      :failed
    end

    def resolve_failure!(consultation)
      LediGenerationFailure.unresolved.where(source_type: SOURCE_TYPE, source_id: consultation.id)
                           .update_all(resolved_at: Time.current, updated_at: Time.current)
    end

    # "Gerar de novo" (contratos §6 do 18), como Ledi::ScreeningFicha.retry!.
    # Falha nascida de um adendo (a ficha já existe): refresh!, que leva o
    # adendo à ficha — generate só diria :exists e resolveria sem regravar.
    def retry!(failure, by:)
      failure.with_lock do
        raise AlreadyResolved if failure.resolved?

        consultation = Consultation.find_by(id: failure.source_id)
        outcome = consultation ? attempt(consultation) : :skipped
        resolve_failure!(consultation) if outcome == :exists
        DomainEvents.publish("ledi.generation_retried", failure_id: failure.id, source_type: failure.source_type,
                                                        source_id: failure.source_id)
      end
      failure.reload
    end

    # Ficha em envio: a falha fica aberta e o job tenta de novo (InFlight).
    def attempt(consultation)
      return generate(consultation) unless latest_entry(consultation)

      refresh!(consultation)
    rescue InFlight
      Ledi::ConsultationFichaJob.enqueue_for(consultation, reason: "addendum")
      :in_flight
    end

    # "Reenviar" recusada: regera da consulta (uuid novo, replaces_outbox_id).
    def regenerate(entry, by:, city: Current.city)
      ApplicationRecord.transaction do
        entry.lock!
        next [ :not_rejected, nil ] unless entry.status == "rejected"
        next [ :not_rejected, nil ] if LediOutboxEntry.exists?(replaces_outbox_id: entry.id)
        next [ :export_unusable, nil ] unless exportable?(city)

        consultation = Consultation.find(entry.source_id)
        ficha, reasons = build(consultation)
        if reasons.any?
          record_failure!(consultation, reasons)
          next [ :generation_failed, nil ]
        end
        fresh = Ledi::Enqueue.call(ficha, city: city, replaces: entry)
        next [ :export_unusable, nil ] unless fresh

        resolve_failure!(consultation)
        DomainEvents.publish("ledi.ficha_resent", outbox_id: entry.id, user_id: by.id)
        [ :ok, fresh ]
      end
    end

    def correction!(accepted, ficha, city)
      existing = LediOutboxEntry.lock.find_by(replaces_outbox_id: accepted.id)
      if existing
        existing.update!(bytes: Ledi::Transport.wrap(ficha, city: city, uuid: existing.uuid))
      else
        uuid = "#{ficha.cnes}-#{SecureRandom.uuid}"
        LediOutboxEntry.create!(uuid: uuid, ficha_type: ficha.type, competence: ficha.competence, source_type: SOURCE_TYPE,
                                source_id: accepted.source_id, ledi_version: Ledi::Version::ACTIVE, status: "correction_pending",
                                next_attempt_at: Time.current, replaces_outbox_id: accepted.id,
                                bytes: Ledi::Transport.wrap(ficha, city: city, uuid: uuid))
      end
      :correction_pending
    end

    # uuidEvolucaoProblema = a linha; coSequencialEvolucao = a posição dela
    # entre as do mesmo problema; dataFimProblema nunca depois do atendimento.
    def problem(row, started)
      day = started.in_time_zone.to_date
      sequence = ConsultationProblem.where(patient_problem_id: row.patient_problem_id)
                                    .where("created_at < ? OR (created_at = ? AND id <= ?)", row.created_at, row.created_at, row.id)
                                    .count
      Ledi::Fichas::IndividualCare::Problem.new(
        uuid: row.patient_problem_id, evolution_uuid: row.id, sequence: sequence,
        ciap: row.terminology == "ciap2" ? row.code : nil, cid10: row.terminology == "cid10" ? row.code : nil,
        situation: Ledi::ConsultationMapping.situation(row.status_after), onset_on: row.onset_on,
        resolved_on: row.resolved_on && [ row.resolved_on, day ].min
      )
    end

    # Medições da consulta; sem nenhuma, as da escuta concluída do mesmo atendimento.
    def measurements(consultation, attendance)
      return consultation if consultation.vitals.any?

      screening = attendance.screening
      screening&.completed? ? screening.current_revision : nil
    end

    def birth_date(patient)
      patient.birth_date.present? ? Date.iso8601(patient.birth_date) : nil
    rescue Date::Error
      nil
    end
    private_class_method :attempt, :latest_entry, :correction!, :problem, :measurements, :birth_date
  end
end
