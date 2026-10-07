require "rails_helper"

# Módulo 18 (ADR 0030; spec §3–§4): o banco garante o que o modelo não vê.
RSpec.describe "Guardas das tabelas da escuta" do
  before { Current.city = TEST_CITY_A; ciap2_release! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:nurse) { screener!(unit) }
  let(:attendance) { walk_in_attendance!(unit, citizen: screening_citizen!(1)) }
  let(:link) { nurse.professional.links.active.sole }

  def attempt(&) = ApplicationRecord.transaction(requires_new: true, &)

  def screening!(status: "in_progress")
    Screening.create!(attendance: attendance, status: "in_progress", started_by_user: nurse, professional_link: link,
                      cbo_code: link.cbo_code, started_at: Time.current).tap do |s|
      s.update!(status: "abandoned") if status == "abandoned"
    end
  end

  def revision!(screening, **over)
    ScreeningRevision.create!({ screening: screening, by_user: nurse, ciap2_code: "K86",
                                ciap2_release_id: TerminologyRelease.active.find_by!(kind: "ciap2").id,
                                systolic: 130, diastolic: 85, final_color: "green" }.merge(over))
  end

  def complete!(screening, destination: "same_day", **over)
    revision = revision!(screening)
    screening.update!({ status: "completed", completed_at: Time.current, destination: destination,
                        current_revision: revision }.merge(over))
    revision
  end

  describe "health_units.screening_scope" do
    it "nasce walk_in e só aceita walk_in ou all" do
      expect(unit.screening_scope).to eq("walk_in")
      expect { attempt { unit.update_columns(screening_scope: "todos") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_health_units_screening_scope/)
    end
  end

  describe "screenings" do
    it "uma por atendimento; DELETE recusado; atendimento nunca muda" do
      screening = screening!
      expect { attempt { screening! } }.to raise_error(ActiveRecord::RecordNotUnique)
      expect { attempt { screening.delete } }.to raise_error(ActiveRecord::StatementInvalid, /DELETE refused/)
      other = walk_in_attendance!(unit, citizen: screening_citizen!(2))
      expect { attempt { screening.update_columns(attendance_id: other.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /identity columns never change/)
    end

    it "transições: em curso → concluída/abandonada; abandonada → em curso; concluída só ganha revisão" do
      screening = screening!(status: "abandoned")
      screening.update!(status: "in_progress", started_at: Time.current)
      revision = complete!(screening)
      expect { attempt { screening.update_columns(status: "abandoned") } }
        .to raise_error(ActiveRecord::StatementInvalid, /only gains revisions/)
      expect { attempt { screening.update_columns(destination: "oriented", orientation_note: "beber água e voltar") } }
        .to raise_error(ActiveRecord::StatementInvalid, /only gains revisions/)
      newer = revision!(screening, final_color: "yellow")
      expect { screening.update!(current_revision: newer) }.not_to raise_error
      expect(revision.reload).to be_persisted
    end

    it "abandonada não vai direto a concluída (precisa voltar a em curso)" do
      screening = screening!(status: "abandoned")
      revision = revision!(screening)
      expect do
        attempt do
          screening.update_columns(status: "completed", completed_at: Time.current, destination: "same_day",
                                   current_revision_id: revision.id)
        end
      end.to raise_error(ActiveRecord::StatementInvalid, /screenings: invalid transition abandoned -> completed/)
    end

    it "CHECKs: concluída exige destino, revisão e hora; orientação só com oriented; schedule exige pedido" do
      screening = screening!
      # update_columns/update! que falham deixam o objeto em memória diferente
      # do banco: cada tentativa parte da linha relida.
      expect { attempt { screening.update_columns(status: "completed", completed_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_screenings_completion/)
      expect { attempt { complete!(screening.reload, destination: "oriented") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_screenings_orientation/)
      expect { attempt { screening.reload.update_columns(orientation_note: "sem destino oriented") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_screenings_orientation/)
      expect { attempt { complete!(screening.reload, destination: "schedule") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_screenings_schedule/)
      expect { attempt { screening.reload.update_columns(destination: "agora") } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_screenings_destination/)
    end
  end

  describe "screening_revisions" do
    it "só acréscimo; plausibilidade, pressão aos pares, glicemia com momento, cor e justificativa" do
      screening = screening!
      revision = revision!(screening)
      expect { attempt { revision.update_columns(final_color: "red") } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      expect { attempt { revision.delete } }.to raise_error(ActiveRecord::StatementInvalid, /append-only/)
      {
        { systolic: 120, diastolic: nil } => /ck_screening_revisions_bp/,
        { systolic: 120, diastolic: 130 } => /ck_screening_revisions_bp/,
        { systolic: 400, diastolic: 80 } => /ck_screening_revisions_systolic/,
        { spo2: 101 } => /ck_screening_revisions_spo2/,
        { capillary_glucose: 120 } => /ck_screening_revisions_glucose/,
        { glucose_moment: "fasting" } => /ck_screening_revisions_glucose/,
        { capillary_glucose: 900, glucose_moment: "random" } => /ck_screening_revisions_glucose/,
        { pain_score: 11 } => /ck_screening_revisions_pain_score/,
        { final_color: "orange" } => /ck_screening_revisions_final_color/,
        { suggested_color: "red", final_color: "green" } => /ck_screening_revisions_color_change/,
        { suggested_color: "red", final_color: "green", color_change_reason: "curta" } => /ck_screening_revisions_color_change_reason/,
        { ciap2_code: "k86" } => /ck_screening_revisions_ciap2/,
        { complaint_note: "x" * 501 } => /ck_screening_revisions_complaint_note/
      }.each do |attrs, error|
        expect { attempt { revision!(screening, **attrs) } }.to raise_error(ActiveRecord::StatementInvalid, error), attrs.inspect
      end
      expect { attempt { revision!(screening, suggested_color: "red", final_color: "yellow",
                                              color_change_reason: "dor torácica já avaliada") } }.not_to raise_error
    end
  end

  describe "attendances (exceção na trava do módulo 13)" do
    # Criados fora das tentativas: o savepoint desfeito levaria o atendimento junto.
    before { attendance; nurse }

    def close_from_waiting(outcome, **extra)
      attempt { attendance.update!({ status: "closed", outcome: outcome, closed_by_user: nurse, closed_at: Time.current }.merge(extra)) }
    end

    it "fechar de waiting como scheduled_from_screening/oriented/referred exige escuta concluída com o destino" do
      expect { close_from_waiting("oriented") }.to raise_error(ActiveRecord::StatementInvalid, /requires a completed screening/)
      expect { close_from_waiting("referred", referral_note: "UPA") }
        .to raise_error(ActiveRecord::StatementInvalid, /requires a completed screening/)
      screening = screening!
      complete!(screening, destination: "same_day")
      expect { close_from_waiting("oriented") }.to raise_error(ActiveRecord::StatementInvalid, /requires a completed screening/)
    end

    it "com a escuta oriented concluída, fecha oriented de waiting; desfecho clínico comum ainda exige chamada" do
      complete!(screening!, destination: "oriented", orientation_note: "hidratação e retorno se piorar")
      expect { close_from_waiting("discharged") }.to raise_error(ActiveRecord::StatementInvalid, /invalid transition/)
      expect { close_from_waiting("oriented") }.not_to raise_error
      expect(attendance.reload.outcome).to eq("oriented")
    end

    it "com a escuta schedule concluída e o pedido aberto, fecha scheduled_from_screening de waiting" do
      screening = screening!
      request = AppointmentRequest.create!(kind: "screening", origin_attendance: attendance, origin_screening: screening,
                                           citizen: attendance.citizen, root_triage: attendance.root_triage,
                                           origin_unit: unit, target_unit: unit, appointment_type_key: appointment_type!.key,
                                           priority: "routine", due_on: Time.zone.today + 7)
      complete!(screening, destination: "schedule", appointment_request: request)
      expect { close_from_waiting("scheduled_from_screening") }.not_to raise_error
      expect(attendance.reload).to have_attributes(status: "closed", outcome: "scheduled_from_screening", called_at: nil)
    end

    it "oriented e scheduled_from_screening nunca saem de in_care" do
      attendance.update!(status: "in_care", called_by_user: nurse, called_at: Time.current)
      expect { attempt { attendance.update!(status: "closed", outcome: "oriented", closed_by_user: nurse, closed_at: Time.current) } }
        .to raise_error(ActiveRecord::StatementInvalid, /invalid transition/)
    end
  end

  describe "appointment_requests kind screening" do
    it "exige a escuta de origem e o atendimento; a origem nunca muda" do
      screening = screening!
      base = { kind: "screening", origin_attendance: attendance, citizen: attendance.citizen,
               root_triage: attendance.root_triage, origin_unit: unit, target_unit: unit,
               appointment_type_key: appointment_type!.key, priority: "routine", due_on: Time.zone.today + 7 }
      expect { attempt { AppointmentRequest.create!(base) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_appointment_requests_screening_kind/)
      request = AppointmentRequest.create!(base.merge(origin_screening: screening))
      other = Screening.create!(attendance: walk_in_attendance!(unit, citizen: screening_citizen!(3)), status: "in_progress",
                                started_by_user: nurse, professional_link: link, cbo_code: link.cbo_code, started_at: Time.current)
      expect { attempt { request.update_columns(origin_screening_id: other.id) } }
        .to raise_error(ActiveRecord::StatementInvalid, /origin columns never change/)
    end
  end

  describe "ledi_generation_failures" do
    it "um aberto por fonte; motivos não vazios" do
      LediGenerationFailure.create!(source_type: "Screening", source_id: SecureRandom.uuid, reason_codes: [ "unit_without_cnes" ])
      id = SecureRandom.uuid
      LediGenerationFailure.create!(source_type: "Screening", source_id: id, reason_codes: [ "citizen_without_sex" ])
      expect { attempt { LediGenerationFailure.create!(source_type: "Screening", source_id: id, reason_codes: [ "citizen_without_sex" ]) } }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect { LediGenerationFailure.new(source_type: "Screening", source_id: SecureRandom.uuid, reason_codes: []).save! }
        .to raise_error(ActiveRecord::RecordInvalid)
      # O modelo recusa antes; o CHECK é a rede de quem grava sem passar por ele.
      row = { source_type: "Screening", source_id: SecureRandom.uuid, reason_codes: [] }
      expect { attempt { LediGenerationFailure.insert_all([ row ]) } }
        .to raise_error(ActiveRecord::StatementInvalid, /ck_ledi_generation_failures_reason_codes/)
    end
  end
end
