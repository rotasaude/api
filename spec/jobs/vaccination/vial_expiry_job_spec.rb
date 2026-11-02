require "rails_helper"

# Módulo 29, Task 7 (ADR 0047, Desvio 8): o vencimento fecha o frasco sem autor
# e grava a perda técnica = doses que sobraram.
RSpec.describe Vaccination::VialExpiryJob do
  include ActiveSupport::Testing::TimeHelpers

  let!(:city) { vaccination_city! }
  let(:room) { vaccine_room! }
  after { Current.reset }

  def run! = described_class.perform_now

  it "vencimento grava a perda técnica com as doses que sobraram" do
    vial = open_vial!(room, lot: vaccine_lot!(room, code: "24", doses: 10)) # SCR, 6 h
    apply_from_vial!(vial, count: 3)
    travel 7.hours do
      run!
      expect(vial.reload).to have_attributes(technical_loss_doses: 7, closed_by_user_id: nil, close_reason: nil)
      expect(vial.closed_at).to be_present
      expect(vial.status).to eq("expired")
      expect(DomainEvent.where(name: "vaccination.vial_closed").map(&:payload))
        .to eq([ { "vial_opening_id" => vial.id, "vaccine_room_id" => room.id, "user_id" => nil, "cause" => "expired" } ])
    end
  end

  it "dose cancelada não conta como usada; frasco esgotado vence sem perda" do
    full = open_vial!(room, lot: vaccine_lot!(room, code: "24"))
    apply_from_vial!(full, count: 10)
    cancelled = open_vial!(room, lot: vaccine_lot!(room, code: "24"))
    apply_from_vial!(cancelled, count: 2).first.update!(cancelled_at: Time.current, cancelled_by_user: room_member!(room, role: "room_lead", cbo: "223505"),
                                                         cancel_reason: "registro duplicado")
    travel(7.hours) { run! }
    expect(full.reload.technical_loss_doses).to eq(0)
    expect(cancelled.reload.technical_loss_doses).to eq(9)
  end

  it "frasco ainda válido, já descartado ou já vencido e fechado não muda; rodar de novo não repete" do
    live = open_vial!(room, lot: vaccine_lot!(room, code: "22")) # 672 h
    discarded = open_vial!(room, lot: vaccine_lot!(room, code: "24"))
    Vaccination::CloseOutVial.call(vial: discarded, reason: "frasco caiu e trincou", by: room_member!(room, role: "room_lead", cbo: "223505"))
    closed_at = discarded.reload.closed_at
    travel 7.hours do
      run!
      run!
    end
    expect(live.reload.closed_at).to be_nil
    expect(discarded.reload).to have_attributes(closed_at: closed_at, technical_loss_doses: 10)
    expect(DomainEvent.where(name: "vaccination.vial_closed").count).to eq(1)
  end

  it "uma falha num frasco não para os demais e o job falha com a contagem" do
    bad = open_vial!(room, lot: vaccine_lot!(room, code: "24"))
    good = open_vial!(room, lot: vaccine_lot!(room, code: "24"))
    allow(VialOpening).to receive(:lock).and_wrap_original do |original, *args|
      relation = original.call(*args)
      allow(relation).to receive(:find).and_wrap_original { |m, id| id == bad.id ? raise(ActiveRecord::StatementInvalid, "boom paciente") : m.call(id) }
      relation
    end
    travel 7.hours do
      expect { run! }.to raise_error(/1 vial\(s\) failed/)
    end
    expect(good.reload.closed_at).to be_present
    expect(bad.reload.closed_at).to be_nil
  end

  it "com a sala de vacina desligada, nada" do
    vial = open_vial!(room, lot: vaccine_lot!(room, code: "24"))
    Platform::Features.set!(city: city, key: "vaccination", enabled: false, maintainer: ledi_maintainer!)
    travel(7.hours) { run! }
    expect(vial.reload.closed_at).to be_nil
  end

  it "está agendado a cada 15 minutos" do
    task = ActiveSupport::ConfigurationFile.parse(Rails.root.join("config/recurring.yml")).fetch("production").fetch("vaccination_vial_expiry")
    expect(task).to include("class" => "Vaccination::VialExpiryJob", "schedule" => "every 15 minutes")
  end
end
