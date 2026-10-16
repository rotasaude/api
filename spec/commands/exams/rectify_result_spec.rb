require "rails_helper"

# Desvio 4: retificação sem UPDATE — novo resultado com replaces_result_id; o
# vigente é o que ninguém substituiu; um original por pedido; ciência perdida.
# Nota #2 (Task 5): a substituição aponta sempre para resultado do MESMO pedido.
RSpec.describe Exams::RectifyResult do
  before { lab_city! }

  let(:unit) { create_unit("UBS Retifica") }
  let(:doctor) { doctor!(unit) }
  let(:provider) { exam_provider! }
  let(:new_values) { [ { "key" => "hba1c", "label" => "HbA1c", "value" => "9.1", "unit" => "%", "loinc" => "4548-4" } ] }

  def resulted_order(seq)
    exam_order!(patient: exam_patient!(seq).first, unit: unit, requester: doctor).tap do |o|
      Exams::Steps.schedule(order: o, actor_user: doctor, params: { provider_id: provider.id, scheduled_at: 1.day.from_now.iso8601, scheduled_place: "Lab" })
      Exams::RegisterResult.call(order: o.reload, source: "unit", file: pdf_file!(user: doctor), released_on: Time.zone.today, laboratory_name: "Lab",
                                 critical: false, values: [ { "key" => "hba1c", "value" => "6.1" } ], by_user: doctor)
    end
  end

  let(:order) do
    exam_catalog_item!
    resulted_order(exam_seq!).tap { |o| Exams::Acknowledge.call(order: o.reload, by: doctor) }
  end

  def rectify(target, critical: false, file: pdf_file!(user: doctor))
    described_class.call(order: target, values: new_values, critical: critical, file: file, laboratory_name: "Lab", by_user: doctor, by_provider: nil)
  end

  it "substitui o vigente, volta a resulted com prazo novo, publica result_rectified" do
    first = order.reload.result
    outcome = rectify(order)
    expect(outcome).to be_ok
    order.reload
    expect(order).to have_attributes(status: "resulted", stage: "acknowledge")
    expect(order.result).to eq(outcome.payload[:result])
    expect(order.result.replaces_result).to eq(first)
    expect(order.results.count).to eq(2)
    expect(ExamResult.current.where(exam_order_id: order.id).sole).to eq(order.result)
    expect(order.events.last.kind).to eq("result_rectified")
    expect(DomainEvent.where(name: "exam_order.result_rectified").sole.payload.keys).to contain_exactly("exam_order_id", "critical")
    expect { ExamResult.create!(first.attributes.except("id", "created_at", "pdf_file_id").merge("pdf_file_id" => pdf_file!(user: doctor).id)) }
      .to raise_error(ActiveRecord::RecordNotUnique)
  end

  it "retifica de novo (cadeia) e o crítico escala uma vez por motivo" do
    second = rectify(order, critical: true).payload[:result]
    third = rectify(order.reload, critical: true).payload[:result]
    order.reload
    expect(order.result).to eq(third)
    expect(third.replaces_result).to eq(second)
    expect(order.results.count).to eq(3)
    expect(order.events.count { |e| e.kind == "escalated" && e.escalation_reason == "critical" }).to eq(1)
  end

  it "recusa pedido sem resultado ou fora de resulted/acknowledged, sem consumir o PDF" do
    exam_catalog_item!
    open_order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor)
    file = pdf_file!(user: doctor)
    outcome = rectify(open_order, file: file)
    expect([ outcome.reason, outcome.details ]).to eq([ :invalid_transition, { status: "awaiting_schedule" } ])
    expect(file.reload).not_to be_consumed
    expect(ExamResult.where(exam_order_id: open_order.id)).to be_empty
  end

  it "recusa arquivo que não é PDF" do
    file = pdf_file!(user: doctor, content_type: "image/png")
    expect(rectify(order, file: file).reason).to eq(:missing_pdf)
    expect(order.reload.results.count).to eq(1)
  end

  it "nota #2: resultado novo não pode substituir resultado de outro pedido" do
    order
    other = resulted_order(exam_seq!).reload.result
    expect do
      ExamResult.create!(exam_order: order, patient: order.patient, sigtap_code: order.sigtap_code, origin: "order", source: "unit",
                         pdf_file: pdf_file!(user: doctor), values: new_values.to_json, released_on: Time.zone.today,
                         laboratory_name: "Lab", critical: false, replaces_result: other)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(other.reload.exam_order.results.count).to eq(1)
  end
end
