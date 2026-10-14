require "rails_helper"

# Spec §5–§6 (F-21.8): o resultado nasce uma vez; campos do catálogo;
# crítico e solicitante digitado vão à fila da equipe já no resultado.
# Review Focus 2: dois resultados ao mesmo tempo.
RSpec.describe Exams::RegisterResult do
  before { exam_city! }

  let(:unit) { create_unit("UBS Resultado") }
  let(:doctor) { doctor!(unit) }
  let(:reception) { staff_with("rec-#{SecureRandom.hex(2)}@cidade.gov.br", "citizen_verifier") }
  let(:order) do
    exam_order!(patient: exam_patient!(90).first, unit: unit, requester: doctor).tap do |o|
      Exams::Steps.schedule(order: o, actor_user: doctor, params: { provider_id: exam_provider!.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
    end
  end

  def register(order, **over)
    described_class.call(order: order.reload, source: "unit", file: pdf_file!(user: reception), released_on: Time.zone.today.iso8601,
                         laboratory_name: "Laboratório Central", critical: false,
                         values: [ { "key" => "hba1c", "value" => "7.9" } ], by_user: reception, **over)
  end

  def typed_order(patient_seq, provider_name)
    exam_catalog_item!
    typed = Exams::Open.call(patient: exam_patient!(patient_seq).first, sigtap_code: "0202010503", priority: "routine", unit: unit,
                             origin: "reception_guide", requester_name: "Dr. Externo", requester_cns: Professionals::Cns.generate("x"),
                             guide_file: pdf_file!(user: reception).tap { |f| f.update!(consumed_at: Time.current) },
                             created_by: reception).payload[:order]
    Exams::Steps.schedule(order: typed, actor_user: reception, params: { provider_id: exam_provider!(name: provider_name).id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    typed
  end

  it "grava o resultado com os campos do catálogo e evento só com ids" do
    result = register(order).payload[:result]
    expect(result.values_list).to eq([ { "key" => "hba1c", "label" => "Hemoglobina glicada", "value" => "7.9", "unit" => "%", "loinc" => "4548-4" } ])
    expect(order.reload.status).to eq("resulted")
    expect(result.pdf_file.consumed?).to be(true)
    expect(result.inspect).not_to include("critical", "7.9")
    expect(DomainEvent.where(name: "exam_order.resulted").order(:occurred_at, :created_at).last.payload).to eq("exam_order_id" => order.id, "source" => "unit", "critical" => false)
    expect(DomainEvent.all.map { |e| e.payload.to_json }.join).not_to include("7.9")
  end

  it "dois resultados ao mesmo tempo: o segundo não entra; cancelado não ganha resultado (Review Focus 2)" do
    register(order)
    expect(register(order).reason).to eq(:result_already_registered)
    expect(ExamResult.where(exam_order_id: order.id).count).to eq(1)
    expect { ExamResult.create!(ExamResult.find_by(exam_order_id: order.id).attributes.except("id").merge("pdf_file_id" => pdf_file!.id)) }
      .to raise_error(ActiveRecord::RecordNotUnique)
    other = exam_order!(patient: exam_patient!(91).first, unit: unit, requester: doctor)
    Exams::Steps.cancel(order: other, reason: "Feito em outro serviço", actor_user: doctor)
    expect(register(other).then { |r| [ r.reason, r.details ] }).to eq([ :invalid_transition, { status: "cancelled" } ])
    expect(ExamResult.where(exam_order_id: other.id)).to be_empty
  end

  it "crítico e solicitante digitado escalam no resultado; valor fora do catálogo recusa" do
    register(order, critical: true)
    expect(order.reload.events.where(kind: "escalated").pluck(:escalation_reason)).to eq(%w[critical])
    typed = typed_order(93, "L2")
    register(typed)
    expect(typed.reload.events.where(kind: "escalated").pluck(:escalation_reason)).to eq(%w[unlinked_requester])
    third = exam_order!(patient: exam_patient!(92).first, unit: unit, requester: doctor)
    Exams::Steps.schedule(order: third, actor_user: doctor, params: { provider_id: exam_provider!(name: "L3").id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    expect(register(third, values: [ { "key" => "glicose", "value" => "1" } ]).reason).to eq(:invalid_values)
    expect(register(third, file: nil).reason).to eq(:missing_pdf)
    expect(register(third, released_on: (Time.zone.today + 1).iso8601).reason).to eq(:invalid_released_on)
  end

  # A31: um escalonamento por motivo; o crítico de solicitante digitado tem os dois.
  it "crítico com solicitante digitado escala pelos dois motivos; escalated_at é o primeiro" do
    typed = typed_order(94, "L4")
    register(typed, critical: true)
    expect(typed.reload.events.where(kind: "escalated").pluck(:escalation_reason)).to contain_exactly("critical", "unlinked_requester")
    expect(DomainEvent.where(name: "exam_order.escalated").map(&:payload))
      .to contain_exactly({ "exam_order_id" => typed.id, "reason" => "critical" }, { "exam_order_id" => typed.id, "reason" => "unlinked_requester" })
  end

  it "recusas de forma sem tocar o pedido, e nada dos valores no motivo" do
    third = exam_order!(patient: exam_patient!(95).first, unit: unit, requester: doctor)
    Exams::Steps.schedule(order: third, actor_user: doctor, params: { provider_id: exam_provider!(name: "L5").id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    expect(register(third, laboratory_name: " ").reason).to eq(:invalid_laboratory)
    expect(register(third, critical: "true").reason).to eq(:invalid_critical)
    expect(register(third, released_on: "13/10/2026").reason).to eq(:invalid_released_on)
    expect(register(third, values: [ { "key" => "hba1c", "value" => "1" }, { "key" => "hba1c", "value" => "2" } ]).reason).to eq(:invalid_values)
    expect(register(third, values: { "key" => "hba1c", "value" => "1" }).reason).to eq(:invalid_values)
    refused = register(third, values: [ { "key" => "hba1c", "value" => "x" * 201 } ])
    expect([ refused.reason, refused.details ]).to eq([ :invalid_values, {} ])
    expect(third.reload.status).to eq("scheduled")
  end

  # Desvio (c): recusa DEPOIS do claim! desfaz o consumo (o upload volta a ser órfão).
  it "upload JPEG do mesmo autor: missing_pdf e o arquivo continua não consumido" do
    jpeg = pdf_file!(user: reception, bytes: "\xFF\xD8\xFF\xE0jpeg".b, content_type: "image/jpeg")
    expect(register(order, file: nil, file_id: jpeg.id).reason).to eq(:missing_pdf)
    expect(jpeg.reload.consumed_at).to be_nil
    expect(order.reload.status).to eq("scheduled")
  end

  it "upload PDF em pedido cancelado: invalid_transition e o arquivo continua não consumido" do
    other = exam_order!(patient: exam_patient!(96).first, unit: unit, requester: doctor)
    Exams::Steps.cancel(order: other, reason: "Feito em outro serviço", actor_user: doctor)
    upload = pdf_file!(user: reception)
    expect(register(other, file: nil, file_id: upload.id).then { |r| [ r.reason, r.details ] }).to eq([ :invalid_transition, { status: "cancelled" } ])
    expect(upload.reload.consumed_at).to be_nil
    expect(ExamResult.where(exam_order_id: other.id)).to be_empty
  end

  it "por upload_id: só o arquivo do mesmo autor, nunca consumido; no portal, prestador e funcionário registram (A35)" do
    lab_user = staff_with("lab-#{SecureRandom.hex(2)}@lab.com.br", "exam_provider")
    provider = order.exam_provider
    alien = pdf_file!(user: doctor)
    expect(register(order, file: nil, file_id: alien.id).reason).to eq(:missing_pdf)
    mine = pdf_file!(user: lab_user)
    result = register(order, file: nil, file_id: mine.id, source: "provider", by_user: lab_user, by_provider: provider).payload[:result]
    expect(result).to have_attributes(source: "provider", registered_by_user_id: lab_user.id, registered_by_provider_id: provider.id,
                                      pdf_file_id: mine.id, exam_provider_id: provider.id)
    expect(order.reload.events.last).to have_attributes(kind: "resulted", actor_user_id: lab_user.id, actor_provider_id: provider.id)
  end
end
