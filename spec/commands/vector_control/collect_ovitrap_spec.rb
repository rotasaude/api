require "rails_helper"

# Módulo 35a, Task 9 (ADR 0054; contrato §6, §11, §17; Q7(5), Q13(2)): a
# coleta da palheta pelo agente de endemias. Janela collected_on −
# installed_on em [ovitrap_collection_days_min, _max] (3 e 10); reinstall
# (padrão !remove) abre a leitura seguinte; remove (padrão false) tira a
# ovitrampa (perdida com condition lost). reinstall == remove depois dos
# padrões → invalid_request path reinstall (Q33).
RSpec.describe VectorControl::CollectOvitrap, type: :model do
  let!(:city) { vector_city! }
  let(:agent) { endemic_agent! }
  let(:neighborhood) { Neighborhood.create!(name: "Centro #{SecureRandom.hex(3)}", source: "manual") }
  let(:block) { city_block!(neighborhood: neighborhood, number: "12") }
  let(:household) { ovitrap_household!(agent, block: block) }
  let(:today) { Time.zone.today }

  def install!(installed_on: today - 11) = ovitrap_installed!(agent: agent, household: household, installed_on: installed_on)

  def collect(ovitrap, by: agent, **over)
    body = { "collected_on" => today.iso8601, "condition" => "ok" }.merge(over.transform_keys(&:to_s))
    described_class.call(ovitrap: ovitrap, params: body, by: by)
  end

  def refusal(result) = [ result.reason, result.details ]

  it "2 dias → collection_out_of_range; 3 e 10 passam; 11 recusa" do
    first = install!
    expect(refusal(collect(first, collected_on: (today - 9).iso8601))).to eq([ :collection_out_of_range, { path: "collected_on" } ])
    expect(collect(first, collected_on: (today - 8).iso8601)).to be_ok

    second = install!
    expect(collect(second, collected_on: (today - 1).iso8601)).to be_ok
    third = install!
    expect(refusal(collect(third, collected_on: today.iso8601))).to eq([ :collection_out_of_range, { path: "collected_on" } ])
    expect(refusal(collect(third, collected_on: (today + 1).iso8601))).to eq([ :invalid_request, { path: "collected_on" } ])
    expect(third.readings.open_readings.count).to eq(1)
  end

  it "reinstall (padrão) abre a leitura seguinte; remove sozinho tira e não reabre" do
    ovitrap = install!(installed_on: today - 10)
    result = collect(ovitrap, collected_on: (today - 5).iso8601, condition: "dry")
    expect(result).to be_ok
    expect(result.payload[:ovitrap].id).to eq(ovitrap.id)
    expect(ovitrap.reload).to have_attributes(status: "active", removed_on: nil, version: 2)
    closed, open = ovitrap.readings.order(:installed_on).to_a
    expect(closed).to have_attributes(collected_on: today - 5, condition: "dry", version: 2)
    expect(open).to have_attributes(installed_on: today - 5, collected_on: nil, epi_week: VectorControl::OvitrapIndex.week_of(today - 5))
    event = DomainEvent.where(name: "ovitrap.collected").sole
    expect(event.payload).to eq("ovitrap_id" => ovitrap.id, "user_id" => agent.id)

    expect(collect(ovitrap, remove: true)).to be_ok
    expect(ovitrap.reload).to have_attributes(status: "removed", removed_on: today, version: 3)
    expect(ovitrap.readings.open_readings).to be_empty
    expect(ovitrap.readings.count).to eq(2)
  end

  it "reinstala e coleta de novo no mesmo dia → collection_out_of_range (0 dias; o mínimo é 1..30), sem escrita" do
    ovitrap = install!(installed_on: today - 5)
    expect(collect(ovitrap)).to be_ok
    before = ovitrap.reload.readings.order(:installed_on).map(&:attributes)
    expect(before.last).to include("installed_on" => today, "collected_on" => nil)

    expect(refusal(collect(ovitrap))).to eq([ :collection_out_of_range, { path: "collected_on" } ])
    expect(ovitrap.reload).to have_attributes(status: "active", version: 2)
    expect(ovitrap.readings.order(:installed_on).map(&:attributes)).to eq(before)
    expect(DomainEvent.where(name: "ovitrap.collected").count).to eq(1)
  end

  it "lost + remove → status lost; lost sem remove continua ativa" do
    kept = install!(installed_on: today - 5)
    expect(collect(kept, condition: "lost")).to be_ok
    expect(kept.reload.status).to eq("active")

    gone = install!(installed_on: today - 5)
    expect(collect(gone, condition: "lost", remove: true)).to be_ok
    expect(gone.reload).to have_attributes(status: "lost", removed_on: today)
  end

  it "sem leitura aberta → reading_not_open path ovitrap_id; removida → ovitrap_not_active path ovitrap_id" do
    # Só por dado legado: a coleta não deixa mais ovitrampa ativa sem leitura (Q33).
    ovitrap = install!(installed_on: today - 5)
    ovitrap.readings.sole.update_columns(collected_on: today, condition: "ok")
    expect(refusal(collect(ovitrap))).to eq([ :reading_not_open, { path: "ovitrap_id" } ])

    removed = install!(installed_on: today - 5)
    expect(collect(removed, remove: true)).to be_ok
    expect(refusal(collect(removed))).to eq([ :ovitrap_not_active, { path: "ovitrap_id" } ])
  end

  it "reinstall == remove depois dos padrões → invalid_request path reinstall, antes de reading_not_open (Q33)" do
    ovitrap = install!(installed_on: today - 5)
    expect(refusal(collect(ovitrap, reinstall: false, remove: false))).to eq([ :invalid_request, { path: "reinstall" } ])
    expect(refusal(collect(ovitrap, reinstall: true, remove: true))).to eq([ :invalid_request, { path: "reinstall" } ])
    expect(refusal(collect(ovitrap, reinstall: false))).to eq([ :invalid_request, { path: "reinstall" } ])
    expect(ovitrap.reload).to have_attributes(status: "active", version: 1)
    expect(ovitrap.readings.open_readings.count).to eq(1)
    expect(DomainEvent.where(name: "ovitrap.collected")).to be_empty

    ovitrap.readings.sole.update_columns(collected_on: today, condition: "ok")
    expect(refusal(collect(ovitrap, reinstall: false, remove: false))).to eq([ :invalid_request, { path: "reinstall" } ])

    kept = install!(installed_on: today - 5)
    expect(collect(kept, reinstall: true, remove: false)).to be_ok
    expect(kept.reload.readings.open_readings.count).to eq(1)
    gone = install!(installed_on: today - 5)
    expect(collect(gone, reinstall: false, remove: true)).to be_ok
    expect(gone.reload.status).to eq("removed")
    stays = install!(installed_on: today - 5)
    expect(collect(stays, remove: false)).to be_ok
    expect(stays.reload).to have_attributes(status: "active")
    expect(stays.readings.open_readings.count).to eq(1)
  end

  it "corpo e escopo: condição fora da lista, boolean malformado, chave a mais; outro agente → out_of_scope" do
    ovitrap = install!(installed_on: today - 5)
    expect(refusal(collect(ovitrap, condition: "wet"))).to eq([ :invalid_request, { path: "condition" } ])
    expect(refusal(collect(ovitrap, reinstall: "yes"))).to eq([ :invalid_request, { path: "reinstall" } ])
    expect(refusal(collect(ovitrap, remove: nil))).to eq([ :invalid_request, { path: "remove" } ])
    expect(refusal(collect(ovitrap, egg_count: 3))).to eq([ :invalid_request, { path: "egg_count" } ])
    expect(collect(ovitrap, by: endemic_agent!).reason).to eq(:out_of_scope)
    expect(collect(ovitrap, by: vector_lab!).reason).to eq(:missing_role)
    expect(DomainEvent.where(name: "ovitrap.collected")).to be_empty
  end
end
