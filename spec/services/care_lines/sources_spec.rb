require "rails_helper"

# ADR 0040 (spec §5): fontes existentes, sem cópia; plano, Desvio 9.
RSpec.describe CareLines::Sources do
  include ActiveSupport::Testing::TimeHelpers

  before do
    care_city!
    sigtap_release!
  end

  let(:unit) { care_unit! }
  let(:doctor) { care_doctor!(unit) }
  let(:nurse) { care_nurse!(unit) }
  let(:today) { Time.zone.today }
  let(:exam) { "0202010503" }
  let(:every) { %W[consultation blood_pressure weight_height exam:#{exam} procedure:0301040095] }

  def citizen_of(patient) = Citizen.find_by!(patient_id: patient.id)

  def load_for(patients, since: today - 365, sources: every)
    described_class.load(patient_ids: Array(patients).map(&:id), sources: sources, since: since)
  end

  def cancel!(order, kind: "cancelled")
    result = Exams::Transition.call(order: order, kind: kind, actor_user: doctor, reason: "pedido duplicado")
    raise "transição recusada: #{result.reason}" if result.failure?
  end

  def external_result!(patient, released_on: today, sigtap_code: exam)
    ExamResult.create!(patient: patient, sigtap_code: sigtap_code, origin: "external", source: "unit",
                       pdf_file: pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }, values: "[]",
                       released_on: released_on, laboratory_name: "Particular", registered_by_user: doctor)
  end

  def order_result!(order, released_on: today, replaces: nil)
    ExamResult.create!(exam_order: order, patient: order.patient, sigtap_code: order.sigtap_code, origin: "order", source: "unit",
                       pdf_file: pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }, values: "[]",
                       released_on: released_on, laboratory_name: "Lab", registered_by_user: doctor, replaces_result: replaces)
  end

  it "consulta (CBO e códigos), PA e peso+altura da consulta e da escuta, exame pedido e procedimento" do
    patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
    care_screening!(unit: unit, citizen: citizen_of(patient), by: nurse, vitals: { "systolic" => 150, "diastolic" => 95 })
    exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: exam, status: :awaiting_authorization)
    cancelled = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: exam, status: :awaiting_authorization)
    cancel!(cancelled)
    raw_procedure!(unit: unit, patient: patient, professional: doctor, sigtap_code: "0301040095", cid10: nil)

    events = load_for(patient).fetch(patient.id)
    expect(events["consultation"].map { |e| [ e.on, e.cbo, e.codes ] }).to eq([ [ today, "225125", [ %w[ciap2 T90] ] ] ])
    expect(events["blood_pressure"].map(&:on)).to eq([ today, today ]) # consulta (130/85) e escuta (150/95)
    expect(events["weight_height"].map(&:on)).to eq([ today ])         # só a consulta tem peso e altura
    expect(events["exam:#{exam}"].map(&:on)).to eq([ today ])          # o cancelado não conta
    expect(events["procedure:0301040095"].map(&:on)).to eq([ today ])
    expect(cancelled.reload.status).to eq("cancelled")
  end

  describe "janela (since) e fuso da cidade" do
    # Eventos de verdade (consulta, escuta, pedido, resultado, procedimento) datados
    # logo antes e logo depois da virada do dia local de `since`. Viajamos para o
    # futuro (vínculos e catálogos já valem) e a cidade é America/Sao_Paulo (UTC-3):
    # 23:30 local do dia anterior é 02:30 UTC do dia `since`.
    let(:since) { today + 10 }

    def events_at(local_time)
      patient = nil
      travel_to(local_time) do
        patient = care_patient!(age: 58, sex: "male", problems: [ %w[ciap2 T90] ], unit: unit, doctor: doctor)
        care_screening!(unit: unit, citizen: citizen_of(patient), by: nurse, vitals: { "systolic" => 150, "diastolic" => 95 })
        exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: exam, status: :awaiting_authorization)
        raw_procedure!(unit: unit, patient: patient, professional: doctor, sigtap_code: "0301040095", cid10: nil,
                       performed_on: local_time.to_date)
      end
      external_result!(patient, released_on: local_time.to_date, sigtap_code: "0202010503")
      patient
    end

    it "usa o fuso da cidade (as datas do teste só diferem se o fuso não for UTC)" do
      expect(Time.zone.utc_offset).to be < 0
    end

    it "o que é anterior a since não vem; 00:30 local do dia since entra, 23:30 local do dia anterior (02:30 UTC de since) não" do
      before_edge = events_at(Time.zone.local(since.year, since.month, since.day, 0, 0) - 30.minutes)
      after_edge = events_at(Time.zone.local(since.year, since.month, since.day, 0, 30))
      ids = [ before_edge, after_edge ]

      loaded = load_for(ids, since: since)
      expect(loaded.fetch(before_edge.id)).to eq({})
      kept = loaded.fetch(after_edge.id)
      expect(kept.keys).to contain_exactly("consultation", "blood_pressure", "weight_height", "exam:#{exam}", "procedure:0301040095")
      expect(kept.values.flatten.map(&:on).uniq).to eq([ since ])

      # controle: com since um dia antes, o mesmo evento da véspera aparece (prova que o filtro é que o excluía)
      earlier = load_for(ids, since: since - 1).fetch(before_edge.id)
      expect(earlier.keys).to contain_exactly("consultation", "blood_pressure", "weight_height", "exam:#{exam}", "procedure:0301040095")
      expect(earlier.values.flatten.map(&:on).uniq).to eq([ since - 1 ])
    end

    it "paciente sem nada vem vazio" do
      patient = care_patient!(age: 40, sex: "female")
      expect(load_for(patient, since: today)).to eq(patient.id => {})
    end
  end

  describe "bordas das fontes" do
    let(:patient) { care_patient!(age: 58, sex: "male", unit: unit, doctor: doctor) }

    it "consulta em rascunho ou descartada não conta (nem como PA, nem como peso+altura)" do
      draft = started_consultation!(unit: unit, doctor: doctor, citizen: citizen_of(patient))
      expect(Consultations::SaveDraft.call(consultation: draft, params: draft_body, by: doctor)).to be_ok

      other = care_patient!(age: 60, sex: "female", unit: unit, doctor: doctor)
      discarded = started_consultation!(unit: unit, doctor: doctor, citizen: citizen_of(other))
      Consultations::SaveDraft.call(consultation: discarded, params: draft_body, by: doctor)
      result = ConsultationDrafts::Discard.call(consultation_id: discarded.id, by: doctor, reason: "aberta por engano")
      raise "descarte recusado: #{result.reason}" if result.failure?

      expect(draft.reload.status).to eq("draft")
      expect(discarded.reload.status).to eq("discarded")
      expect(load_for([ patient, other ])).to eq(patient.id => {}, other.id => {})
    end

    it "escuta abandonada não conta, mesmo com revisão de sinais" do
      attendance = walk_in_attendance!(unit, citizen: citizen_of(patient))
      started = Screenings::Start.call(attendance: attendance, by: nurse).payload[:screening]
      attrs = Screenings::RevisionInput.call(revision_params("vitals" => { "systolic" => 150, "diastolic" => 95, "weight_kg" => "70", "height_cm" => 170 }),
                                             citizen: citizen_of(patient)).payload[:attrs]
      revision = ScreeningRevision.create!(attrs.merge(screening: started, by_user: nurse))
      started.update!(current_revision: revision)
      expect(Screenings::Abandon.call(screening: started.reload, by: nurse)).to be_ok

      expect(started.reload.status).to eq("abandoned")
      expect(load_for(patient)).to eq(patient.id => {})
    end

    it "procedimentos 0301100039 e 0101040024 viram blood_pressure e weight_height (e continuam como procedure:*)" do
      raw_procedure!(unit: unit, patient: patient, professional: doctor, sigtap_code: described_class::BP_PROCEDURE, cid10: nil)
      raw_procedure!(unit: unit, patient: patient, professional: doctor, sigtap_code: described_class::WH_PROCEDURE, cid10: nil,
                     performed_on: today - 3)
      sources = %w[blood_pressure weight_height procedure:0301100039 procedure:0101040024]

      events = load_for(patient, sources: sources).fetch(patient.id)
      expect(events["blood_pressure"].map(&:on)).to eq([ today ])
      expect(events["weight_height"].map(&:on)).to eq([ today - 3 ])
      expect(events["procedure:0301100039"].map(&:on)).to eq([ today ])
      expect(events["procedure:0101040024"].map(&:on)).to eq([ today - 3 ])
      # só as fontes pedidas
      expect(load_for(patient, sources: %w[blood_pressure]).fetch(patient.id).keys).to eq(%w[blood_pressure])
    end

    it "procedimento cancelado não conta" do
      kept = raw_procedure!(unit: unit, patient: patient, professional: doctor, sigtap_code: "0301040095", cid10: nil, performed_on: today - 1)
      gone = raw_procedure!(unit: unit, patient: patient, professional: doctor, sigtap_code: "0301040095", cid10: nil)
      result = Billing::Cancel.call(procedure: gone, reason: "lançado por engano", by: doctor)
      raise "cancelamento recusado: #{result.reason}" if result.failure?

      expect(gone.reload.status).to eq("cancelled")
      expect(load_for(patient).fetch(patient.id).fetch("procedure:0301040095").map(&:on)).to eq([ kept.performed_on ])
    end
  end

  describe "exames: um evento por exame" do
    let(:patient) { care_patient!(age: 58, sex: "male", unit: unit, doctor: doctor) }

    def exam_dates(patient) = load_for(patient).fetch(patient.id, {}).fetch("exam:#{exam}", []).map(&:on)

    it "pedido e resultado em dias diferentes são um só evento, com a data do resultado" do
      order = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: exam, status: :awaiting_authorization)
      order_result!(order, released_on: today + 3)

      expect(exam_dates(patient)).to eq([ today + 3 ])
    end

    it "resultado substituto (retificação) não soma" do
      order = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: exam, status: :awaiting_authorization)
      first = order_result!(order, released_on: today + 1)
      order_result!(order, released_on: today + 2, replaces: first)

      expect(exam_dates(patient)).to eq([ today + 2 ])
    end

    it "pedido só na consulta (sem exam_orders, com exam_tracking desligado) conta" do
      finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen_of(patient),
                              exam_requests: [ { "sigtap_code" => exam, "sigtap_competence" => Time.zone.today.strftime("%Y%m") } ])

      expect(ConsultationExamRequest.where(status: "requested").count).to eq(1)
      expect(ExamOrder.where(patient_id: patient.id)).to be_empty
      expect(exam_dates(patient)).to eq([ today ])
    end

    it "pedido da consulta cuja ordem foi cancelada NÃO conta; o negado também não" do
      other = care_patient!(age: 61, sex: "female", unit: unit, doctor: doctor)
      requests = [ patient, other ].map do |person|
        consultation = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen_of(person),
                                               exam_requests: [ { "sigtap_code" => exam, "sigtap_competence" => today.strftime("%Y%m") } ])
        request = consultation.exam_requests.sole
        order = ExamOrder.create!(patient: person, sigtap_code: exam, sigtap_competence: today.strftime("%Y%m"), priority: "routine",
                                  requester_user: doctor, unit: unit, origin: "consultation", consultation_exam_request: request,
                                  short_code: ClinicalDocuments::Codes.short_code, status: "awaiting_authorization",
                                  status_changed_at: Time.current)
        ExamOrderEvent.create!(exam_order: order, kind: "requested", actor_user: doctor, occurred_at: Time.current)
        order
      end
      expect(exam_dates(patient)).to eq([ today ]) # com a ordem viva, o pedido (A) e a ordem (B) são o mesmo exame
      cancel!(requests.first)
      cancel!(requests.last, kind: "denied")

      expect(exam_dates(patient)).to eq([])
      expect(exam_dates(other)).to eq([])
    end

    it "resultado externo, sem ordem, conta (um por resultado)" do
      external_result!(patient, released_on: today - 5)
      external_result!(patient, released_on: today - 2)

      expect(exam_dates(patient)).to eq([ today - 5, today - 2 ])
    end

    describe "adendo (exam_tracking desligado): vale o pedido efetivo, como Consultations::Effective" do
      let(:request) { { "sigtap_code" => exam } }
      let(:consultation) do
        finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen_of(patient), exam_requests: [ request ])
      end

      def amend!(consultation, exam_requests)
        result = Consultations::AddAddendum.call(consultation: consultation, by: doctor, reason: "ajuste do pedido de exame",
                                                 text: "Adendo", changes: { "exam_requests" => exam_requests })
        raise "adendo recusado: #{result.reason} #{result.details}" if result.failure?
      end

      it "pedido normal: a data do pedido é o dia da finalização" do
        expect(consultation.exam_requests.sole.created_at.in_time_zone.to_date).to eq(consultation.finalized_at.in_time_zone.to_date)
        expect(exam_dates(patient)).to eq([ today ])
      end

      it "adendo que remove o exame: o pedido deixa de contar" do
        consultation
        amend!(consultation, [])

        expect(consultation.exam_requests.order(:created_at, :id).map(&:status)).to eq(%w[requested cancelled])
        expect(exam_dates(patient)).to eq([])
      end

      it "adendo que troca a justificativa (remove e acrescenta o mesmo código): um evento" do
        consultation
        amend!(consultation, [ { "sigtap_code" => exam, "cid10_justification" => "I10" } ]) # sem travel_to: o relógio congelado empata created_at

        expect(consultation.exam_requests.order(:created_at, :id).map(&:status)).to eq(%w[requested cancelled requested])
        expect(exam_dates(patient)).to eq([ today ])
      end

      it "pedido acrescentado só por adendo conta, com a data do adendo" do
        empty = finalized_consultation!(unit: unit, doctor: doctor, citizen: citizen_of(patient), exam_requests: [])
        expect(exam_dates(patient)).to eq([])
        travel_to(Time.zone.now + 4.days) { amend!(empty, [ request ]) }

        expect(exam_dates(patient)).to eq([ today + 4 ])
      end
    end

    it "ordem negada não conta" do
      order = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: exam, status: :awaiting_authorization)
      cancel!(order, kind: "denied")

      expect(exam_dates(patient)).to eq([])
    end
  end

  it "uma consulta por fonte: o número de SQL não cresce com o número de pacientes" do
    patients = Array.new(5) do
      care_patient!(age: 50, sex: "female", problems: [ %w[ciap2 K86] ], unit: unit, doctor: doctor).tap do |patient|
        care_screening!(unit: unit, citizen: citizen_of(patient), by: nurse, vitals: { "systolic" => 140, "diastolic" => 90 })
        order = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: exam, status: :awaiting_authorization)
        order_result!(order)
        raw_procedure!(unit: unit, patient: patient, professional: doctor, sigtap_code: "0301040095", cid10: nil)
      end
    end
    count = lambda do |people|
      queries = 0
      callback = ->(*, payload) { queries += 1 unless payload[:name].in?(%w[SCHEMA TRANSACTION]) || payload[:sql].start_with?("SAVEPOINT", "RELEASE") }
      ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { load_for(people) }
      queries
    end

    expect(load_for(patients).values.map(&:keys)).to all(contain_exactly("consultation", "blood_pressure", "weight_height", "exam:#{exam}", "procedure:0301040095"))
    expect(count.call(patients.first(1))).to eq(count.call(patients))
    expect(count.call(patients)).to be <= 6
  end
end
