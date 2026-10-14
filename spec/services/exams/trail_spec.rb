require "rails_helper"

# Trilha da leitura clínica do exame (contrato §12, A27): o mesmo
# clinical_record.viewed do 19a, só ids; a visão administrativa não deixa
# trilha.
RSpec.describe Exams::Trail do
  before { exam_city! }

  let(:unit) { create_unit("UBS Trilha") }
  let(:doctor) { doctor!(unit) }
  let(:order) { exam_order!(patient: exam_patient!(40).first, unit: unit, requester: doctor) }

  def viewed = DomainEvent.where(name: "clinical_record.viewed")

  it "leitura clínica grava access e exam_order_id; a administrativa não grava" do
    grant = Exams::Access.for_order(user: doctor, order: order)
    expect { described_class.viewed!(order: order, user: doctor, grant: grant) }.to change { viewed.count }.by(1)
    expect(viewed.last.payload).to eq("patient_id" => order.patient_id, "user_id" => doctor.id, "access" => "author",
                                      "reason_code" => nil, "exam_order_id" => order.id)
    admin = Exams::Access::Grant.new(view: :administrative, kind: :unit, opening: nil)
    expect { described_class.viewed!(order: order, user: doctor, grant: admin) }.not_to(change { viewed.count })
    expect { described_class.viewed!(order: order, user: doctor, grant: nil) }.not_to(change { viewed.count })
  end

  it "o laudo grava access exam_result com exam_result_id e exam_order_id" do
    file = pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }
    result = ExamResult.create!(exam_order: order, patient: order.patient, sigtap_code: order.sigtap_code, origin: "order",
                                source: "unit", pdf_file: file, values: "[]", released_on: Time.zone.today,
                                laboratory_name: "Lab", critical: false, registered_by_user: doctor)
    described_class.result_viewed!(result: result, user: doctor)
    expect(viewed.last.payload).to eq("patient_id" => order.patient_id, "user_id" => doctor.id, "access" => "exam_result",
                                      "reason_code" => nil, "exam_result_id" => result.id, "exam_order_id" => order.id)
  end
end
