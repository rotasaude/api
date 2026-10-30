require "rails_helper"

# Módulo 28 (ADR 0046; contrato §16 O2, O6; api-constraints Desvio 8, Review
# Focus 4): o adendo da consulta odontológica corrige o odontograma (`findings`)
# e cancela itens previstos do plano (`plan_changes.cancel`); nada de
# procedimento, item novo, cancel_plan nem especialidade. Só achado/cancelamento
# não muda a FAO: nenhum ConsultationFichaJob. Recusa não grava nada.
RSpec.describe Consultations::AddAddendum do
  include ActiveSupport::Testing::TimeHelpers

  before { Current.city = dental_city! }
  after { Current.reset }

  let(:unit) { create_unit }
  let(:dentist) { dentist!(unit) }
  let(:citizen) { verified_citizen!(1) }
  let(:reason) { "Dente com indicação de exodontia" }

  def restoration(tooth) = { "sigtap" => "0307010031", "location" => { "kind" => "tooth", "tooth" => tooth } }

  def finalized!(by: dentist, who: citizen, **over) = finalized_dental!(unit: unit, by: by, citizen: who, **over)

  def with_plan!(items: [ 21, 22 ])
    finalized!(dental: { "plan_changes" => { "add" => items.map { |t| restoration(t) } } })
  end

  def plan = DentalTreatmentPlan.find_by!(health_unit: unit)

  def add(consultation, dental, by: consultation.author_user, **args)
    described_class.call(consultation: consultation, by: by, reason: "correção do odontograma", text: "Texto do adendo",
                         changes: { "dental" => dental }, **args)
  end

  def clear_enqueued_jobs = ActiveJob::Base.queue_adapter.enqueued_jobs.clear
  def chart(consultation) = DentalCare::Chart.call(consultation.patient)[:teeth].index_by { |t| t[:tooth] }
  def failed(result) = [ result.reason, result.details[:path] ]

  it "achado novo vira evento com o adendo, muda o odontograma, entra em changes e não enfileira ficha" do
    consultation = finalized!
    clear_enqueued_jobs
    result = nil
    expect { result = add(consultation, { "findings" => [ { "tooth" => 26, "situation" => "caries" } ] }) }
      .not_to have_enqueued_job(Ledi::ConsultationFichaJob)
    expect(result).to be_ok
    addendum = result.payload[:addendum]
    event = DentalChartEvent.find_by!(addendum_id: addendum.id)
    expect(event).to have_attributes(consultation_id: consultation.id, tooth: 26, part: "crown", situation: "caries",
                                     author_user_id: dentist.id, cbo_code: consultation.cbo_code)
    expect(chart(consultation)[26][:situation]).to eq("caries")
    expect(addendum.item_changes).to eq("dental" => { "findings" => [ { "tooth" => 26, "face" => nil, "part" => "crown", "arch" => nil,
                                                                         "situation" => "caries" } ] })
    expect(result.payload[:structured]).to be(true)
    expect(result.payload[:ficha_changed]).to be(false)
    expect(Consultations::Json.addendum(addendum)[:changes]).to eq(
      "dental" => { findings: [ { tooth: "26", face: nil, part: "crown", arch: nil, situation: "caries" } ] }
    )
  end

  it "o adendo e a assinatura nascem como antes; o evento publicado só leva ids" do
    consultation = finalized!
    addendum = add(consultation, { "findings" => [ { "tooth" => 26, "situation" => "caries" } ] }).payload[:addendum]
    expect(addendum).to have_attributes(text: "Texto do adendo", reason: "correção do odontograma", author_user_id: dentist.id)
    expect(DomainEvent.where(name: "consultation.addendum_added").sole.payload)
      .to eq("consultation_id" => consultation.id, "addendum_id" => addendum.id)
    expect(DomainEvent.pluck(:payload).to_json).not_to include("caries")
  end

  it "o achado corrigido vence o da consulta (dobra por recorded_at, seq)" do
    consultation = finalized!(dental: { "findings" => [ { "tooth" => 26, "situation" => "caries" } ] })
    expect(chart(consultation)[26][:situation]).to eq("caries")
    travel(1.minute) do
      add(consultation, { "findings" => [ { "tooth" => 26, "situation" => "sound" } ] })
    end
    expect(chart(consultation)[26][:situation]).to eq("sound")
    # o bloco da consulta segue sem os eventos do adendo
    expect(Consultations::Json.consultation(consultation.reload)[:dental][:findings].map { |f| f[:situation] }).to eq([ "caries" ])
  end

  it "cancela item previsto com motivo: cancelled, cancelled_in_addendum_id, sem job, fora do bloco da consulta" do
    consultation = with_plan!
    item = plan.items.order(:tooth).first
    clear_enqueued_jobs
    result = nil
    expect do
      result = add(consultation, { "plan_changes" => { "cancel" => [ { "item_id" => item.id, "reason" => reason } ] } })
    end.not_to have_enqueued_job(Ledi::ConsultationFichaJob)
    expect(result).to be_ok
    addendum = result.payload[:addendum]
    expect(item.reload).to have_attributes(status: "cancelled", cancel_reason: reason, cancelled_in_addendum_id: addendum.id,
                                           cancelled_in_consultation_id: nil)
    expect(plan.items.where(status: "planned").count).to eq(1)
    expect(plan.status).to eq("open")
    expect(Consultations::Json.addendum(addendum)[:changes]).to eq(
      "dental" => { plan_changes: { cancel: [ { item_id: item.id, reason: reason } ] } }
    )
    expect(Consultations::Json.consultation(consultation.reload)[:dental][:plan_changes][:cancel]).to eq([])
  end

  it "achado e cancelamento juntos, na mesma transação" do
    consultation = with_plan!
    item = plan.items.order(:tooth).first
    result = add(consultation, { "findings" => [ { "tooth" => 21, "situation" => "extraction_indicated" } ],
                                 "plan_changes" => { "cancel" => [ { "item_id" => item.id, "reason" => reason } ] } })
    expect(result).to be_ok
    expect(result.payload[:addendum].item_changes["dental"].keys).to match_array(%w[findings plan_changes])
    expect(chart(consultation)[21][:situation]).to eq("extraction_indicated")
    expect(item.reload.status).to eq("cancelled")
  end

  it "Review Focus 4: plano já concluído — o achado vira evento; cancelar item dele → plan_item_not_open, nada gravado" do
    first = with_plan!(items: [ 21 ])
    item = plan.items.sole
    second = finalized!(dental: { "dental_consultation_type" => 2, "dental_outcomes" => [ 15 ],
                                  "procedures" => [ restoration(21).merge("plan_item_id" => item.id) ] })
    expect(plan.reload).to have_attributes(status: "completed")
    clear_enqueued_jobs

    # só o achado: entra, muda o odontograma, não regera a FAO
    expect { expect(add(second, { "findings" => [ { "tooth" => 22, "situation" => "fracture" } ] })).to be_ok }
      .not_to have_enqueued_job(Ledi::ConsultationFichaJob)
    expect(chart(second)[22][:situation]).to eq("fracture")

    before = [ ConsultationAddendum.count, DentalChartEvent.count, DomainEvent.count ]
    result = add(second, { "findings" => [ { "tooth" => 23, "situation" => "caries" } ],
                           "plan_changes" => { "cancel" => [ { "item_id" => item.id, "reason" => reason } ] } })
    expect(failed(result)).to eq([ :plan_item_not_open, "changes.dental.plan_changes.cancel[0].item_id" ])
    expect([ ConsultationAddendum.count, DentalChartEvent.count, DomainEvent.count ]).to eq(before)
    expect(item.reload.status).to eq("done")
    expect(first).to be_present
  end

  it "item já cancelado, de outro paciente ou inexistente → plan_item_not_open no índice certo" do
    consultation = with_plan!
    items = plan.items.order(:tooth).to_a
    add(consultation, { "plan_changes" => { "cancel" => [ { "item_id" => items[0].id, "reason" => reason } ] } })
    other = finalized!(who: verified_citizen!(2), dental: { "plan_changes" => { "add" => [ restoration(31) ] } })
    foreign = DentalTreatmentPlanItem.where.not(id: items.map(&:id)).sole
    [ [ items[0].id, 0 ], [ foreign.id, 0 ], [ SecureRandom.uuid, 0 ] ].each do |id, index|
      result = add(consultation, { "plan_changes" => { "cancel" => [ { "item_id" => id, "reason" => reason } ] } })
      expect(failed(result)).to eq([ :plan_item_not_open, "changes.dental.plan_changes.cancel[#{index}].item_id" ])
    end
    result = add(consultation, { "plan_changes" => { "cancel" => [ { "item_id" => items[1].id, "reason" => reason },
                                                                    { "item_id" => items[0].id, "reason" => reason } ] } })
    expect(failed(result)).to eq([ :plan_item_not_open, "changes.dental.plan_changes.cancel[1].item_id" ])
    expect(items[1].reload.status).to eq("planned")
    expect(other).to be_present
  end

  it "motivo curto do cancelamento → invalid_reason com o caminho; achado inválido recusado" do
    consultation = with_plan!
    item = plan.items.first
    result = add(consultation, { "plan_changes" => { "cancel" => [ { "item_id" => item.id, "reason" => "curto" } ] } })
    expect(failed(result)).to eq([ :invalid_reason, "changes.dental.plan_changes.cancel[0].reason" ])
    result = add(consultation, { "findings" => [ { "tooth" => 99, "situation" => "caries" } ] })
    expect(result).to be_failure
    expect(result.details[:path]).to eq("changes.dental.findings[0].tooth")
    expect(ConsultationAddendum.count).to eq(0)
    expect(DentalChartEvent.where.not(addendum_id: nil).count).to eq(0)
  end

  it "só achado e cancelamento: o resto → invalid_changes com changes.dental.<chave>" do
    consultation = with_plan!
    {
      "procedures" => [ restoration(21) ],
      "periodontal_chart" => { "teeth" => [] },
      "endodontics" => [],
      "dental_outcomes" => [ 15 ]
    }.each do |key, value|
      result = add(consultation, { key => value })
      expect(failed(result)).to eq([ :invalid_changes, "changes.dental.#{key}" ]), key
    end
    result = add(consultation, { "plan_changes" => { "add" => [ restoration(23) ] } })
    expect(failed(result)).to eq([ :invalid_changes, "changes.dental.plan_changes.add" ])
    result = add(consultation, { "plan_changes" => { "cancel_plan" => { "reason" => reason } } })
    expect(failed(result)).to eq([ :invalid_changes, "changes.dental.plan_changes.cancel_plan" ])
    expect(add(consultation, "lixo")).to be_failure
    expect(plan.reload.status).to eq("open")
    expect(ConsultationAddendum.count).to eq(0)
  end

  it "consulta geral com changes.dental → invalid_changes; as chaves gerais seguem valendo" do
    Current.city = clinical_city!
    expect(described_class::CHANGE_KEYS).to include("dental", "evaluated_problems", "conducts", "exam_requests")
    ciap2_release!
    cid10_release!
    sigtap_release!
    doctor = doctor!(unit)
    general = finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(3))
    result = described_class.call(consultation: general, by: doctor, reason: "correção do pedido", text: "x",
                                  changes: { "dental" => { "findings" => [ { "tooth" => 26, "situation" => "caries" } ] } })
    expect(failed(result)).to eq([ :invalid_changes, "changes.dental" ])
    expect(ConsultationAddendum.count).to eq(0)
  end

  it "TSB/ASB: achado vale; cancelar item do plano → auxiliary_cannot_plan" do
    owner = with_plan!
    expect(owner).to be_present
    assistant = auxiliary!(unit)
    consultation = finalized!(by: assistant, who: verified_citizen!(4),
                              dental: { "procedures" => [ { "sigtap" => "0101020066", "location" => { "kind" => "tooth", "tooth" => 16 } } ] })
    expect(add(consultation, { "findings" => [ { "tooth" => 26, "situation" => "caries" } ] })).to be_ok
    item = plan.items.first
    result = add(consultation, { "plan_changes" => { "cancel" => [ { "item_id" => item.id, "reason" => reason } ] } })
    expect(failed(result)).to eq([ :auxiliary_cannot_plan, "changes.dental.plan_changes" ])
    expect(item.reload.status).to eq("planned")
  end

  it "interruptor desligado: changes.dental → feature_disabled; sem dental, o adendo geral passa" do
    consultation = finalized!
    Platform::Features.set!(city: Current.city, key: "dental_care", enabled: false, maintainer: ledi_maintainer!)
    result = add(consultation, { "findings" => [ { "tooth" => 26, "situation" => "caries" } ] })
    expect(result.reason).to eq(:feature_disabled)
    expect(result.details[:feature]).to eq("dental_care")
    expect(ConsultationAddendum.count).to eq(0)
  end

  it "só a autora e consulta finalizada, como no adendo geral" do
    consultation = finalized!
    other = dentist!(unit)
    expect(add(consultation, { "findings" => [ { "tooth" => 26, "situation" => "caries" } ] }, by: other).reason).to eq(:not_author)
    expect(DentalChartEvent.where.not(addendum_id: nil).count).to eq(0)
  end
end
