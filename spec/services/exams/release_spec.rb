require "rails_helper"

# Spec §6 "Cidadão" (F-21.10): immediate ao registrar; after_acknowledgement
# depois da ciência; never_citizen nunca; fora do catálogo = padrão
# after_acknowledgement; resultado externo nasce com ciência. Contrato A23/A29:
# antes de o cidadão poder saber, `result` é null e o rótulo é o da etapa
# anterior ao resultado.
RSpec.describe Exams::Release do
  before { exam_city! }

  let(:unit) { create_unit("UBS Liberação") }
  let(:doctor) { doctor!(unit) }

  def scheduled(sigtap:, policy:)
    exam_catalog_item!(sigtap_code: sigtap, release_policy: policy, result_fields: [])
    order = exam_order!(patient: exam_patient!(exam_seq!).first, unit: unit, requester: doctor, sigtap_code: sigtap)
    Exams::Steps.schedule(order: order, actor_user: doctor, params: { provider_id: exam_provider!(name: "L#{SecureRandom.hex(2)}").id,
                                                                      scheduled_at: 1.day.from_now.iso8601, scheduled_place: "L" })
    order.reload
  end

  def resulted(sigtap:, policy:, collect: false)
    order = scheduled(sigtap: sigtap, policy: policy)
    Exams::Steps.collect(order: order, actor_user: doctor) if collect
    Exams::RegisterResult.call(order: order.reload, source: "unit", file: pdf_file!(user: doctor), released_on: Time.zone.today.iso8601,
                               laboratory_name: "Lab", critical: false, values: [], by_user: doctor).payload[:result]
  end

  it "as três políticas" do
    expect(described_class.available?(resulted(sigtap: "0202020380", policy: "immediate"))).to be(true)
    waiting = resulted(sigtap: "0202010503", policy: "after_acknowledgement")
    expect(described_class.available?(waiting)).to be(false)
    Exams::Acknowledge.call(order: waiting.exam_order, by: doctor)
    expect(described_class.available?(waiting.reload)).to be(true)
    never = resulted(sigtap: "0202030300", policy: "never_citizen")
    Exams::Acknowledge.call(order: never.exam_order, by: doctor)
    expect(described_class.available?(never)).to be(false)
    expect(described_class.pickup_at_unit?("0202030300")).to be(true)
    expect(described_class.policy("0202999999")).to eq("after_acknowledgement")
  end

  describe ".citizen_label / .citizen_result (um lugar só: lista e linha do tempo)" do
    it "after_acknowledgement antes da ciência: result null e a etapa anterior ao resultado" do
      from_scheduled = resulted(sigtap: "0202010503", policy: "after_acknowledgement").exam_order
      expect(described_class.citizen_label(from_scheduled)).to eq("Agendado")
      expect(described_class.citizen_result(from_scheduled)).to be_nil

      from_collected = resulted(sigtap: "0202010503", policy: "after_acknowledgement", collect: true).exam_order
      expect(described_class.citizen_label(from_collected)).to eq("Coletado")
      expect(described_class.citizen_result(from_collected)).to be_nil

      Exams::Acknowledge.call(order: from_collected, by: doctor)
      from_collected.reload
      expect(described_class.citizen_label(from_collected)).to eq("Resultado disponível")
      expect(described_class.citizen_result(from_collected))
        .to eq(available: true, pickup_at_unit: false, released_on: Time.zone.today.iso8601, pdf_available: true)
    end

    it "never_citizen: etapa anterior até a ciência; depois retire na unidade, nunca o laudo nem a data (A37)" do
      order = resulted(sigtap: "0202030300", policy: "never_citizen", collect: true).exam_order
      expect([ described_class.citizen_label(order), described_class.citizen_result(order) ]).to eq([ "Coletado", nil ])
      expect(described_class.citizen_status(order)).to eq("collected")
      expect(Exams::Acknowledge.call(order: order, by: doctor)).to be_ok
      order.reload
      expect(described_class.citizen_label(order)).to eq("Retire o resultado na sua unidade")
      expect(described_class.citizen_result(order)).to eq(available: false, pickup_at_unit: true, released_on: nil, pdf_available: false)
      expect(described_class.citizen_status(order)).to eq("acknowledged")
    end

    it "resultado de pedido vale como o próprio pedido; outro objeto é ArgumentError" do
      result = resulted(sigtap: "0202020380", policy: "immediate", collect: true)
      expect(described_class.citizen_label(result)).to eq(described_class.citizen_label(result.exam_order))
      expect(described_class.citizen_result(result)).to eq(described_class.citizen_result(result.exam_order))
      expect(described_class.citizen_status(result)).to eq("resulted")
      waiting = resulted(sigtap: "0202010503", policy: "after_acknowledgement")
      expect([ described_class.citizen_label(waiting), described_class.citizen_status(waiting) ]).to eq([ "Agendado", "scheduled" ])
      expect { described_class.citizen_label(Object.new) }.to raise_error(ArgumentError)
    end

    it "política lida uma vez por exame dentro de Release.cached" do
      orders = 3.times.map { resulted(sigtap: "0202020380", policy: "immediate").exam_order }
      count = 0
      counter = ->(*, payload) { count += 1 if payload[:sql].include?("exam_catalog_items") }
      ActiveSupport::Notifications.subscribed(counter, "sql.active_record") do
        described_class.cached { orders.each { |o| [ described_class.citizen_label(o), described_class.citizen_result(o) ] } }
      end
      expect(count).to eq(1)
      expect(described_class.cached { 42 }).to eq(42)
    end

    it "sem resultado: o rótulo da situação e result null" do
      order = scheduled(sigtap: "0202020380", policy: "immediate")
      expect([ described_class.citizen_label(order), described_class.citizen_result(order) ]).to eq([ "Agendado", nil ])
    end

    it "resultado externo segue a política do exame" do
      patient = exam_patient!(exam_seq!).first
      external = ExamResult.create!(patient: patient, sigtap_code: "0202010503", origin: "external", source: "unit",
                                    pdf_file: pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }, values: "[]",
                                    released_on: Time.zone.today, laboratory_name: "Particular", registered_by_user: doctor)
      expect(described_class.citizen_label(external)).to eq("Resultado disponível")
      expect(described_class.citizen_status(external)).to eq("external")
      expect(described_class.citizen_result(external)[:available]).to be(true)
      exam_catalog_item!(sigtap_code: "0202030300", release_policy: "never_citizen", result_fields: [])
      hidden = ExamResult.create!(patient: patient, sigtap_code: "0202030300", origin: "external", source: "unit",
                                  pdf_file: pdf_file!(user: doctor).tap { |f| f.update!(consumed_at: Time.current) }, values: "[]",
                                  released_on: Time.zone.today, laboratory_name: "Particular", registered_by_user: doctor)
      expect(described_class.available?(hidden)).to be(false)
      expect(described_class.citizen_label(hidden)).to eq("Retire o resultado na sua unidade")
    end
  end
end
