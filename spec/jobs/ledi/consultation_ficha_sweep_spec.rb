require "rails_helper"

# Task 16b (módulo 19a): o varredor diário das 23h também gera a ficha da
# consulta finalizada que ficou sem ficha (exportação inutilizável na
# finalização). Mesmas regras do varredor da escuta (módulo 18).
RSpec.describe "Varredor da ficha da consulta" do
  include ActiveSupport::Testing::TimeHelpers

  let(:city) { ledi_ready!(clinical_city!, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902") }
  let(:unit) { create_unit }
  let(:doctor) { doctor!(unit) }
  let(:at23) { Time.utc(2026, 10, 9, 2, 10) } # 23h10 em São Paulo, 8/out

  around { |ex| CityConnection.with(city) { ex.run } }
  before do
    Current.city = city
    ActiveJob::Base.queue_adapter.enqueued_jobs.clear
    ciap2_release!; cid10_release!; sigtap_release!
    allow(Ledi::DeliverJob).to receive(:perform_later)
    exportable_unit!(unit, doctor)
  end
  after { Current.reset }

  # finalized_at é imutável (trigger): finaliza-se na data desejada.
  def finalized!(n, at: nil)
    build = -> { finalized_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(n), exam_requests: []) }
    at ? travel_to(at, &build) : build.call
  end

  def sweep!(at = at23) = travel_to(at) { Ledi::ScreeningFichaSweepJob.perform_now }
  def entries_for(consultation) = LediOutboxEntry.where(source_type: "Consultation", source_id: consultation.id)

  it "gera a ficha da consulta finalizada da competência atual, uma só vez" do
    consultation = finalized!(1, at: Time.utc(2026, 10, 2, 15))
    2.times { |i| sweep!(at23 + i.minutes) }
    expect(entries_for(consultation).count).to eq(1)
  end

  it "gera na competência anterior" do
    consultation = finalized!(1, at: Time.utc(2026, 9, 2, 15))
    sweep!
    expect(entries_for(consultation).count).to eq(1)
  end

  it "ignora a finalizada antes do início do mês passado" do
    old = finalized!(1, at: Time.utc(2026, 8, 20, 15))
    recent = finalized!(2, at: Time.utc(2026, 9, 2, 15))
    sweep!
    expect([ entries_for(old).count, entries_for(recent).count ]).to eq([ 0, 1 ])
  end

  it "não toca consulta com 'não gerada' (resolvida ou não)" do
    open = finalized!(1, at: Time.utc(2026, 10, 2, 15))
    resolved = finalized!(2, at: Time.utc(2026, 10, 2, 15))
    LediGenerationFailure.create!(source_type: "Consultation", source_id: open.id, reason_codes: [ "citizen_without_sex" ])
    LediGenerationFailure.create!(source_type: "Consultation", source_id: resolved.id, reason_codes: [ "citizen_without_sex" ],
                                  resolved_at: Time.current)
    sweep!
    expect([ entries_for(open).count, entries_for(resolved).count ]).to eq([ 0, 0 ])
  end

  it "não duplica a consulta que já tem ficha" do
    consultation = finalized!(1, at: Time.utc(2026, 10, 2, 15))
    Ledi::ConsultationFicha.generate(consultation)
    sweep!
    expect(entries_for(consultation).count).to eq(1)
  end

  it "ignora consulta em rascunho" do
    draft = started_consultation!(unit: unit, doctor: doctor, citizen: verified_citizen!(1))
    sweep!
    expect([ entries_for(draft).count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
  end

  it "fora das 23h locais não faz nada" do
    consultation = finalized!(1, at: Time.utc(2026, 10, 2, 15))
    sweep!(Time.utc(2026, 10, 9, 1, 10)) # 22h10 em São Paulo
    expect(entries_for(consultation).count).to eq(0)
  end

  it "exportação ainda inutilizável: nada (nem 'não gerada'); tenta na noite seguinte" do
    consultation = finalized!(1, at: Time.utc(2026, 10, 2, 15))
    ledi_off!(city)
    sweep!
    expect([ LediOutboxEntry.count, LediGenerationFailure.count ]).to eq([ 0, 0 ])
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "record", ibge_code: "4106902")
    sweep!(at23 + 1.day)
    expect(entries_for(consultation).count).to eq(1)
  end
end
