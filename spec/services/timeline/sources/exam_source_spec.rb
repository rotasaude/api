require "rails_helper"

# Contrato §10 (F-21.13, api#71) com A23/A24/A29/A32/A37: o exame na linha do
# tempo — profissional vê pedido, etapa e "resultado registrado" (nunca
# valores nem crítico); cidadão vê o andamento e o laudo só pela política de
# Exams::Release (o mesmo lugar de "Meus exames"); janela e cursor como os
# outros.
RSpec.describe Timeline::Sources::ExamSource do
  include ActiveSupport::Testing::TimeHelpers

  before { exam_city!; Platform::Features.set!(city: Current.city, key: "patient_timeline", enabled: true, maintainer: ledi_maintainer!) }

  let(:unit) { create_unit("UBS Linha") }
  let(:doctor) { doctor!(unit) }
  let(:patient) { exam_patient!(exam_seq!).first }
  let(:person) { Timeline::Person.for_patient(patient) }

  def entries = described_class.entries(person: person, before: nil, limit: 10, from: nil, to: nil)

  def scheduled(sigtap:, policy:)
    exam_catalog_item!(sigtap_code: sigtap, release_policy: policy, result_fields: [])
    order = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: sigtap)
    Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: exam_provider!(name: "L#{SecureRandom.hex(2)}").id,
                                                                      scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    order.reload
  end

  def resulted(sigtap:, policy:, critical: false)
    order = scheduled(sigtap: sigtap, policy: policy)
    Exams::RegisterResult.call(order: order, source: "unit", file: pdf_file!(user: doctor), released_on: Time.zone.today.iso8601,
                               laboratory_name: "Lab", critical: critical, values: [], by_user: doctor)
    order.reload
  end

  def external!(sigtap)
    ExamResult.create!(patient: patient, sigtap_code: sigtap, origin: "external", source: "unit",
                       pdf_file: pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }, values: "[]",
                       released_on: Time.zone.today, laboratory_name: "Particular", registered_by_user: doctor)
  end

  def entry_of(id) = entries.find { |e| e.source_id == id }

  it "pedidos e resultado externo, na ordem total, com a visão do cidadão pela política" do
    first = travel_to(2.days.ago) { resulted(sigtap: "0202020380", policy: "immediate", critical: true) }
    external = external!("0202010503")
    list = entries
    expect(list.map(&:source_id)).to eq([ external.id, first.id ])
    order_entry = list.last
    expect(order_entry).to have_attributes(kind: "exam", title: "HEMOGRAMA COMPLETO", status: "resulted",
                                           summary: "Resultado registrado", detail_ref: { type: "exam_order", id: first.id })
    expect(order_entry.citizen).to include(status: "resulted", status_label: "Resultado disponível", summary: "Resultado disponível")
    expect(order_entry.document).to eq(id: first.id, short_code: nil, verification_url: nil, downloadable: true)
    expect(list.first).to have_attributes(status: "external", unit: nil, detail_ref: { type: "exam_result", id: external.id },
                                          document: { id: external.id, short_code: nil, verification_url: nil, downloadable: true })
    expect(list.first.citizen).to include(status: "external", status_label: "Resultado disponível")
    expect(list.first.summary).to eq("Resultado externo — Particular")
    expect(list.map(&:to_h).to_s).not_to include("critical")
    expect(list.map { |e| Timeline::Json.citizen(e) }.to_s).not_to include("Particular", "Lab")
  end

  it "after_acknowledgement antes da ciência: o cidadão vê a etapa anterior, sem documento; o profissional vê o resultado (A23/A29)" do
    order = resulted(sigtap: "0202010503", policy: "after_acknowledgement")
    entry = entry_of(order.id)
    expect(entry).to have_attributes(status: "resulted", summary: "Resultado registrado", document: nil)
    expect(entry.citizen).to include(status: "scheduled", status_label: "Agendado", summary: "Agendado")
    expect(Timeline::Json.citizen(entry).to_s).not_to include("Resultado", "resulted")

    expect(Exams::Acknowledge.call(order: order, by: doctor)).to be_ok
    entry = entry_of(order.id)
    expect(entry.citizen).to include(status: "acknowledged", status_label: "Resultado disponível")
    expect(entry.document).to eq(id: order.id, short_code: nil, verification_url: nil, downloadable: true)
  end

  it "never_citizen: etapa anterior até a ciência, depois retire na unidade; nunca documento (A37)" do
    order = resulted(sigtap: "0202030300", policy: "never_citizen")
    expect(entry_of(order.id).citizen).to include(status: "scheduled", status_label: "Agendado")
    expect(Exams::Acknowledge.call(order: order, by: doctor)).to be_ok
    entry = entry_of(order.id)
    expect(entry.citizen).to include(status: "acknowledged", status_label: "Retire o resultado na sua unidade")
    expect(entry.document).to be_nil
    hidden = external!("0202030300")
    expect(entry_of(hidden.id)).to have_attributes(document: nil)
    expect(entry_of(hidden.id).citizen).to include(status_label: "Retire o resultado na sua unidade")
  end

  it "sem resultado: etapa pendente para o profissional, rótulo da situação para o cidadão; negado sem motivo" do
    open = exam_order!(patient: patient, unit: unit, requester: doctor)
    exam_catalog_item!(sigtap_code: "0202020380", requires_authorization: true, result_fields: [])
    denied = exam_order!(patient: patient, unit: unit, requester: doctor, sigtap_code: "0202020380")
    ApplicationRecord.transaction do
      denied.lock!
      Exams::Transition.call(order: denied, kind: "denied", actor_user: doctor, reason: "Sem indicação clínica descrita")
    end
    expect(entry_of(open.id)).to have_attributes(summary: "Agendamento pendente", status: "awaiting_schedule", document: nil)
    expect(entry_of(open.id).citizen).to include(status: "awaiting_schedule", status_label: "Pedido registrado")
    expect(entry_of(denied.id)).to have_attributes(summary: "Pedido negado", status: "denied")
    expect(entry_of(denied.id).citizen).to include(status_label: "Pedido não autorizado — procure sua unidade")
    expect(entries.map(&:to_h).to_s).not_to include("Sem indicação")
  end

  it "Json.citizen: status_label só quando presente; document do exame com as quatro chaves (A24)" do
    order = exam_order!(patient: patient, unit: unit, requester: doctor)
    json = Timeline::Json.citizen(entry_of(order.id))
    expect(json).to include(status_label: "Pedido registrado", document: nil)
    plain = Timeline::Entry.new(kind: "campaign", source_id: SecureRandom.uuid, occurred_at: Time.current, unit: nil, professional: nil,
                                title: "T", summary: nil, status: nil, detail_ref: nil,
                                citizen: { title: "T", summary: nil, status: nil, professional_name: nil }, document: nil)
    expect(Timeline::Json.citizen(plain)).not_to have_key(:status_label)
  end

  it "com exam_tracking desligado não entra nada; sem paciente, nada" do
    exam_order!(patient: patient, unit: unit, requester: doctor)
    Platform::Features.set!(city: Current.city, key: "exam_tracking", enabled: false, maintainer: ledi_maintainer!)
    expect(entries).to eq([])
    Platform::Features.set!(city: Current.city, key: "exam_tracking", enabled: true, maintainer: ledi_maintainer!)
    empty = Timeline::Person.new(citizen_ids: [], patient_id: nil, verified: true)
    expect(described_class.entries(person: empty, before: nil, limit: 10, from: nil, to: nil)).to eq([])
  end

  it "pagina pela janela comum sem repetir, misturando pedidos e externos" do
    ids = 4.times.map do |i|
      travel_to(i.minutes.ago) { i.even? ? exam_order!(patient: patient, unit: unit, requester: doctor).id : external!("0202010503").id }
    end
    page = Timeline::Query.call(person: person, kinds: %w[exam], limit: 3)
    rest = Timeline::Query.call(person: person, kinds: %w[exam], limit: 3, before: Timeline::Cursor.decode(page.next_before))
    expect((page.entries + rest.entries).map(&:source_id)).to eq(ids)
    expect(rest.next_before).to be_nil
    expect(described_class.entries(person: person, before: nil, limit: 2, from: nil, to: nil).map(&:source_id)).to eq(ids.first(2))
  end

  it "mesmo instante: desempate pelo id, como a Query (C6)" do
    at = 1.hour.ago.change(usec: 0)
    rows = travel_to(at) { [ exam_order!(patient: patient, unit: unit, requester: doctor).id, external!("0202010503").id ] }
    expect(entries.map(&:source_id)).to eq(rows.sort)
  end

  it "o catálogo é lido uma vez por exame da página, não por linha" do
    3.times { resulted(sigtap: "0202020380", policy: "immediate") }
    2.times { external!("0202010503") }
    count = 0
    counter = ->(*, payload) { count += 1 if payload[:sql].include?("exam_catalog_items") }
    ActiveSupport::Notifications.subscribed(counter, "sql.active_record") { entries }
    expect(count).to eq(2)
  end

  it "o nome do exame é resolvido uma vez por (código, competência) da página, não por linha" do
    3.times { resulted(sigtap: "0202020380", policy: "immediate") }
    calls = 0
    allow(ClinicalTerms::SigtapExams).to receive(:label).and_wrap_original { |m, *a| calls += 1; m.call(*a) }
    expect(entries.size).to eq(3)
    expect(calls).to eq(1)
  end
end
