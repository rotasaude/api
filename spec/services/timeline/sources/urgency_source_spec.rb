require "rails_helper"

# Linha do tempo da urgência (ADR 0050; contrato §10 e §14 Q13, Q25; plano
# Task 14). Profissional: a UPA, a cor vigente, o 1º CID-10 avaliado, o
# desfecho e a orientação de retorno com o motivo, em qualquer estado.
# Cidadão: só encontros fechados, a UPA, a chegada, o desfecho pela tabela W3 e
# `return_guidance` sem o motivo; nunca CID, cor, queixa, critério, óbito nem
# registro por engano; o provisório nunca, e depois da identificação o
# encontro aparece no histórico do real. A visita não sai duas vezes: nem a
# consulta de urgência, nem o atendimento walk_in, nem (para o cidadão) as
# linhas do BPA da urgência.
RSpec.describe Timeline::Sources::UrgencySource do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { urgency_city! }
  let(:upa) { upa!(name: "UPA Boqueirão") }
  let(:nurse) { upa_nurse!(upa) }
  let(:doctor) { upa_doctor!(upa) }
  let(:patient) { urgency_patient!(1) }

  before { ciap2_release!; cid10_release!; sigtap_release! }

  def entries(person, citizen: false) = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil, citizen: citizen)
  def citizen_query(person) = Timeline::Query.call(person: person, kinds: Timeline::Query.citizen_kinds(verified: true, documents: true), citizen_view: true)

  # Classificado em laranja (dor 9 → a regra sugerida "Dor intensa"), chamado,
  # consulta de urgência finalizada com o CID e o desfecho gravado.
  def closed!(kind, patient: self.patient, attrs: {}, cid10: "I10")
    e = arrived!(upa, patient: patient).tap { |x| classified!(x, color: "orange", by: nurse, pain_scale: 9) }
    called!(e, by: doctor)
    finalized_urgency!(e, doctor: doctor, cid10: cid10)
    result = Urgency::RecordOutcome.call(encounter: e.reload, attrs: { "kind" => kind }.merge(attrs), by: doctor)
    raise "desfecho recusado: #{result.reason}" if result.failure?

    e.reload
  end

  it "profissional vê cor, CID e orientação; cidadão só unidade, data, desfecho simples e o prazo" do
    urgency_protocol!
    e = closed!("discharged_to_primary_care", attrs: { "return_guidance" => { "days" => 5, "reason" => "Ajustar anti-hipertensivo" } })
    consultation = Consultation.find_by!(attendance_id: e.attendance_id)
    entry = entries(Timeline::Person.for_patient(patient)).sole
    expect(entry).to have_attributes(kind: "urgency", source_id: e.id, occurred_at: e.attendance.checked_in_at,
                                     unit: { id: upa.id, name: "UPA Boqueirão" }, status: "closed",
                                     title: "Atendimento de urgência — UPA Boqueirão",
                                     professional: { name: Screenings::Json.staff_name(doctor), cbo_code: consultation.cbo_code },
                                     detail_ref: { type: "consultation", id: consultation.id }, document: nil)
    expect(entry.summary).to eq("Laranja · I10 Hipertensão essencial (primária) · Alta com retorno na UBS · " \
                                "Retorno à UBS em até 5 dias: Ajustar anti-hipertensivo")

    citizen = Timeline::Json.citizen(entries(Timeline::Person.for_patient(patient), citizen: true).sole)
    expect(citizen).to eq(id: "urgency:#{e.id}", kind: "urgency", occurred_at: e.attendance.checked_in_at.iso8601,
                          unit: { name: "UPA Boqueirão" }, professional_name: nil, title: "Atendimento de urgência — UPA Boqueirão",
                          summary: "Alta, com orientação para procurar a sua UBS", status: nil, document: nil,
                          return_guidance: "Procure a sua UBS em até 5 dias")
    expect(citizen.to_s).not_to include("I10", "Hipertens", "Laranja", "orange", "anti-hipertensivo", "Dor intensa",
                                        UrgencyHelpers::COMPLAINT)
  end

  it "um dia no singular; desfecho sem orientação não leva return_guidance" do
    closed!("discharged_to_primary_care", attrs: { "return_guidance" => { "days" => 1, "reason" => "Curativo" } })
    closed!("discharged", cid10: nil)
    person = Timeline::Person.for_patient(patient)
    professional = entries(person).index_by { |entry| entry.summary.include?("Retorno") }
    expect(professional[true].summary).to end_with("Retorno à UBS em até 1 dia: Curativo")
    expect(professional[false].summary).to eq("Laranja · Alta")
    citizen = entries(person, citizen: true).map { |entry| Timeline::Json.citizen(entry) }
    expect(citizen.map { |c| [ c[:summary], c[:return_guidance] ] })
      .to contain_exactly([ "Alta, com orientação para procurar a sua UBS", "Procure a sua UBS em até 1 dia" ],
                          [ "Atendimento concluído, com alta", nil ])
    expect(citizen.find { |c| c[:summary] == "Atendimento concluído, com alta" }).not_to have_key(:return_guidance)
  end

  it "cidadão: só fechados, pela tabela W3; nunca óbito nem registro por engano; o profissional vê todos" do
    labels = { "discharged" => "Atendimento concluído, com alta", "transferred" => "Transferido(a) para outro serviço",
               "left_against_advice" => "Saiu antes da alta médica", "death" => nil }
    closed = labels.keys.to_h do |kind|
      attrs = kind == "transferred" ? { "destination" => "Hospital Regional" } : {}
      [ kind, closed!(kind, attrs: attrs) ]
    end
    left = arrived!(upa, patient: patient)
    Urgency::RecordOutcome.call(encounter: left, attrs: { "kind" => "left_without_care" }, by: upa_reception!)
    error = arrived!(upa, patient: patient)
    Urgency::RecordOutcome.call(encounter: error, attrs: { "kind" => "registered_in_error", "reason" => "Chegada lançada em duplicidade" },
                                by: upa_reception!)
    waiting = arrived!(upa, patient: patient).tap { |x| classified!(x, color: "green", by: nurse, pain_scale: 5) }

    person = Timeline::Person.for_patient(patient)
    expect(entries(person).map(&:source_id))
      .to match_array(closed.values.map(&:id) + [ left.id, error.id, waiting.id ])
    professional = entries(person).index_by(&:source_id)
    expect(professional[closed["death"].id].summary).to end_with("Óbito")
    expect(professional[error.id].summary).to eq("Registrado por engano")
    expect(professional[waiting.id]).to have_attributes(status: "classified", summary: "Verde", detail_ref: nil, professional: nil)
    expect(professional[left.id]).to have_attributes(summary: "Saiu sem atendimento", detail_ref: nil)
    expect(professional[closed["left_against_advice"].id].summary).to end_with("Saiu contra orientação médica")
    expect(professional[closed["transferred"].id].summary).to end_with("Transferência")

    citizen = entries(person, citizen: true)
    expect(citizen.map(&:source_id)).to match_array(closed.except("death").values.map(&:id) + [ left.id ])
    expect(citizen.map { |entry| Timeline::Json.citizen(entry)[:summary] })
      .to match_array(labels.values.compact + [ "Saiu antes do atendimento" ])
    payload = citizen.map { |entry| Timeline::Json.citizen(entry) }.to_s
    expect(payload).not_to include("Óbito", "death", "engano", "registered_in_error", "duplicidade", "Hospital Regional", "Verde")
    expect(Timeline::Sources::Labels::CITIZEN_URGENCY_OUTCOMES.keys)
      .to match_array(Urgency::Catalog::OUTCOMES - %w[death] - Urgency::Catalog::NON_CARE_OUTCOMES)
  end

  it "provisório não aparece para o cidadão; depois da fusão, aparece no histórico do real e some a consulta duplicada" do
    e = arrived!(upa, unidentified: "Homem, 45 anos").tap { |x| classified!(x, color: "green", by: nurse, pain_scale: 5) }
    called!(e, by: doctor)
    finalized_urgency!(e, doctor: doctor, cid10: "I10")
    Urgency::RecordOutcome.call(encounter: e.reload, attrs: { "kind" => "left_against_advice" }, by: doctor)
    provisional = e.reload.patient
    expect(entries(Timeline::Person.for_patient(provisional)).map(&:source_id)).to eq([ e.id ])
    expect(entries(Timeline::Person.for_patient(provisional), citizen: true)).to be_empty
    expect(citizen_query(Timeline::Person.for_cpf(patient.cpf)).entries).to be_empty

    result = Urgency::Identify.call(encounter: e, patient_id: patient.id, by: upa_reception!)
    expect(result).to be_ok
    kinds = Timeline::Query.call(person: Timeline::Person.for_patient(patient)).entries.map(&:kind)
    expect(kinds).to include("urgency")
    expect(kinds).not_to include("consultation", "attendance")
    citizen = citizen_query(Timeline::Person.for_cpf(patient.cpf)).entries
    expect(citizen.map { |entry| [ entry.kind, entry.source_id ] }).to eq([ [ "urgency", e.id ] ])
    expect(Timeline::Json.citizen(citizen.first)[:summary]).to eq("Saiu antes da alta médica")
    expect(entries(Timeline::Person.for_patient(provisional.reload))).to be_empty
  end

  it "AttendanceSource nunca emite o walk_in; a consulta de urgência não sai pela ConsultationSource" do
    e = closed!("discharged")
    # O ck_attendances_citizen já impede walk_in com cidadão (a linha não chega
    # à fonte por citizen_id): sem como montar o caso, confere-se o filtro
    # explícito no SQL da fonte, a defesa contra a regra do banco mudar.
    expect(Timeline::Sources::AttendanceSource.scope(Timeline::Person.for_patient(patient)).to_sql)
      .to include("walk_in")
    expect(Timeline::Sources::ConsultationSource.entries(person: Timeline::Person.for_patient(patient), before: nil, limit: 10,
                                                         from: nil, to: nil)).to be_empty
    expect(Consultation.where(attendance_id: e.attendance_id).sole.kind).to eq("urgency")
  end

  it "fail-closed: sem o recorte do cidadão no SQL, Json.citizen pula óbito, aberto, provisório e registro por engano" do
    shown = closed!("discharged")
    death = closed!("death")
    error = arrived!(upa, patient: patient)
    Urgency::RecordOutcome.call(encounter: error, attrs: { "kind" => "registered_in_error", "reason" => "Chegada lançada em duplicidade" },
                                by: upa_reception!)
    open = arrived!(upa, patient: patient).tap { |x| classified!(x, color: "yellow", by: nurse, pain_scale: 3) }
    provisional = arrived!(upa, unidentified: "Homem, 30 anos")
    Urgency::RecordOutcome.call(encounter: provisional, attrs: { "kind" => "left_without_care" }, by: upa_reception!)

    real = Timeline::Query.call(person: Timeline::Person.for_patient(patient), kinds: %w[urgency]).entries
    expect(real.map(&:source_id)).to contain_exactly(shown.id, death.id, error.id, open.id)
    expect(real.filter_map { |entry| Timeline::Json.citizen(entry) }.map { |c| c[:id] }).to eq([ "urgency:#{shown.id}" ])
    expect(real.reject { |entry| entry.source_id == shown.id }.map(&:citizen)).to all(be_nil)
    unidentified = Timeline::Query.call(person: Timeline::Person.for_patient(provisional.patient), kinds: %w[urgency]).entries
    expect(unidentified.map(&:source_id)).to eq([ provisional.id ])
    expect(unidentified.filter_map { |entry| Timeline::Json.citizen(entry) }).to be_empty
  end

  it "janela e cursor pela chegada" do
    older = travel_to(2.days.ago) { closed!("discharged") }
    newer = closed!("discharged")
    person = Timeline::Person.for_patient(patient)
    page = Timeline::Query.call(person: person, kinds: %w[urgency], limit: 1)
    expect(page.entries.map(&:source_id)).to eq([ newer.id ])
    rest = Timeline::Query.call(person: person, kinds: %w[urgency], limit: 1, before: Timeline::Cursor.decode(page.next_before))
    expect(rest.entries.map(&:source_id)).to eq([ older.id ])
    expect(Timeline::Query.call(person: person, kinds: %w[urgency], from: 1.day.ago).entries.map(&:source_id)).to eq([ newer.id ])
  end

  context "documentos do walk_in (19c): sem cidadão, pelo paciente" do
    before { documents_city! }

    it "aparecem nas duas visões e baixam pelo cidadão; do óbito, o documento não diz o desfecho" do
      e = closed!("death")
      document = ClinicalDocument.create!(kind: "attendance_declaration", patient_id: patient.id, citizen_id: nil, attendance: e.attendance,
                                          author_user_id: upa_reception!.id, issue_mode: "paper",
                                          verification_token: ClinicalDocuments::Codes.token, short_code: ClinicalDocuments::Codes.short_code,
                                          issued_at: Time.current, content: "{}")
      person = Timeline::Person.for_patient(patient)
      source = Timeline::Sources::ClinicalDocumentSource.entries(person: person, before: nil, limit: 10, from: nil, to: nil)
      expect(source.map(&:source_id)).to eq([ document.id ])
      expect(Timeline::CitizenDocuments.find(person: Timeline::Person.for_cpf(patient.cpf), id: document.id)).to eq(document)
      expect(Timeline::CitizenDocuments.find(person: Timeline::Person.for_cpf(urgency_patient!(2).cpf), id: document.id)).to be_nil

      citizen = citizen_query(Timeline::Person.for_cpf(patient.cpf)).entries
      expect(citizen.map(&:kind)).to eq(%w[clinical_document])
      expect(citizen.map { |entry| Timeline::Json.citizen(entry) }.to_s).not_to include("Óbito", "death", "urgência")
    end

    it "o registro da Notificação de receita do walk_in sai pela ControlledNotificationSource, pelo paciente" do
      e = closed!("discharged")
      consultation = Consultation.find_by!(attendance_id: e.attendance_id)
      record = ClinicalDocument.create!(kind: "controlled_notification_record", patient_id: patient.id, citizen_id: nil, attendance: e.attendance,
                                        consultation: consultation, author_user_id: doctor.id, cbo_code: consultation.cbo_code,
                                        issue_mode: "paper", verification_token: ClinicalDocuments::Codes.token,
                                        short_code: ClinicalDocuments::Codes.short_code, issued_at: Time.current,
                                        content: { "notification_type" => "B", "paper_number" => "123456" }.to_json)
      person = Timeline::Person.for_patient(patient)
      expect(Timeline::Sources::ControlledNotificationSource.entries(person: person, before: nil, limit: 10, from: nil, to: nil)
                                                            .map(&:source_id)).to eq([ record.id ])
      expect(Timeline::Sources::ClinicalDocumentSource.entries(person: person, before: nil, limit: 10, from: nil, to: nil)).to be_empty
      expect(Timeline::CitizenDocuments.find(person: Timeline::Person.for_cpf(patient.cpf), id: record.id)).to be_nil
    end
  end

  context "linhas do BPA da urgência (22)" do
    let!(:city) { urgency_city!(billing: true) }
    let(:upa) { upa!(name: "UPA Boqueirão").tap { |u| u.update!(cnes: billing_cnes) } }

    it "o profissional segue vendo as linhas; o cidadão não (a entrada da urgência já resume a visita, óbito inclusive)" do
      e = closed!("death")
      perform_enqueued_jobs(only: Billing::UrgencyProductionJob)
      lines = PerformedProcedure.where(urgency_encounter_id: e.id)
      expect(lines.count).to eq(2)
      person = Timeline::Person.for_patient(patient)
      professional = Timeline::Query.call(person: person, kinds: %w[procedure]).entries
      expect(professional.map(&:source_id)).to match_array(lines.ids)
      expect(Timeline::Query.call(person: person, kinds: %w[procedure], citizen_view: true).entries).to be_empty
      expect(citizen_query(Timeline::Person.for_cpf(patient.cpf)).entries).to be_empty
    end
  end

  describe "horas de observação (32b, Task 14)" do
    let(:bed) { urgency_bed!(upa) }
    let(:other_bed) { urgency_bed!(upa) }
    let(:t0) { Time.current.change(usec: 0) - 10.hours }

    def in_care!(patient: self.patient) = in_care_encounter!(upa, patient: patient)

    it "conta da PRIMEIRA entrada ao último ended_at (troca de leito não zera), em horas inteiras; o resumo ganha 'observação N h'" do
      e = in_care!
      observed!(e, bed: bed, now: t0)
      last = observed!(e, bed: other_bed, now: t0 + 3.hours)
      last.update!(ended_at: t0 + 6.hours + 50.minutes, end_kind: "outcome", ended_by_user: doctor)
      entry = entries(Timeline::Person.for_patient(patient)).sole
      expect(entry.observation_hours).to eq(6)
      expect(entry.summary).to include("observação 6 h")
      expect(Timeline::Json.professional(entry)).to include(observation_hours: 6)
    end

    it "estadia aberta conta até agora" do
      e = in_care!
      observed!(e, bed: bed, now: t0)
      travel_to(t0 + 5.hours + 30.minutes) do
        entry = entries(Timeline::Person.for_patient(patient)).sole
        expect(entry.observation_hours).to eq(5)
        expect(entry.summary).to include("observação 5 h")
      end
    end

    it "sem estadia: nulo, sem texto, e a chave sai nula só na urgência" do
      in_care!
      entry = entries(Timeline::Person.for_patient(patient)).sole
      expect(entry.observation_hours).to be_nil
      expect(entry.summary.to_s).not_to include("observação")
      expect(Timeline::Json.professional(entry)).to include(observation_hours: nil)
    end

    it "outras fontes não ganham a chave e o cidadão não vê nada" do
      other = Timeline::Entry.new(kind: "attendance", source_id: "x", occurred_at: Time.current, unit: nil, professional: nil, title: "t",
                                  summary: nil, status: nil, detail_ref: nil, citizen: nil, document: nil)
      expect(other.observation_hours).to be_nil
      expect(Timeline::Json.professional(other)).not_to have_key(:observation_hours)
    end

    it "o cidadão não recebe horas nem o texto" do
      urgency_protocol!
      e = closed!("discharged")
      observed_bed = urgency_bed!(upa)
      expect(e.reload.bed_stays).to be_empty
      citizen = Timeline::Json.citizen(entries(Timeline::Person.for_patient(patient), citizen: true).sole)
      expect(citizen.to_s).not_to include("observation_hours", "observação")
      expect(observed_bed).to be_present
    end

    it "as estadias vêm em preload: sem N+1" do
      3.times do |i|
        p = urgency_patient!(urgency_seq!)
        observed!(in_care!(patient: p), bed: urgency_bed!(upa), now: t0 + i.minutes)
      end
      person = Timeline::Person.for_patient(patient)
      stays = 0
      counter = ->(*, payload) { stays += 1 if payload[:sql].include?("urgency_bed_stays") && payload[:sql].start_with?("SELECT") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { entries(person) }
      few = stays
      stays = 0
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { entries(person) }
      expect(few).to eq(stays)
      expect(few).to be <= 1
    end
  end
end
