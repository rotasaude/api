require "rails_helper"

# api#19 (fechamento do módulo 07; ADR-0013): o telefone de quem mandou
# (InboundMessage#from) e de quem recebeu (OutboundMessage#to) é dado pessoal e
# fica cifrado em repouso, com a chave determinística DA CIDADE — a busca por
# igualdade (SessionWindow, índices em from/to) continua funcionando.
RSpec.describe "Telefone das mensagens cifrado" do
  before { Current.city = TEST_CITY_A }

  def make_inbound(from)
    InboundMessage.create!(message_id: "wamid.#{SecureRandom.hex(8)}", from: from, kind: "text", raw: "{}")
  end

  def stored_from(id)
    InboundMessage.connection.select_value(
      InboundMessage.sanitize_sql(["SELECT \"from\" FROM inbound_messages WHERE id = ?", id])
    )
  end

  it "grava o telefone cifrado e o lê de volta na cidade" do
    msg = make_inbound("5541999990000")

    expect(stored_from(msg.id)).not_to include("5541999990000")
    expect(ActiveRecord::Encryption.encryptor.encrypted?(stored_from(msg.id))).to be(true)
    expect(InboundMessage.find(msg.id).from).to eq("5541999990000")
  end

  it "continua achando por igualdade (a busca da janela de 24h)" do
    make_inbound("5541999990001")

    expect(InboundMessage.where(from: "5541999990001").count).to eq(1)
  end

  it "não casa o mesmo telefone gravado por outra cidade" do
    make_inbound("5541999990002")

    expect(CityConnection.with(TEST_CITY_B) { InboundMessage.where(from: "5541999990002").count }).to eq(0)
  end

  describe "OutboundMessage#to" do
    def make_outbound(to)
      OutboundMessage.create!(to: to, template: { "name" => "x" }, idempotency_key: "idem-#{SecureRandom.hex(8)}", status: 200)
    end

    def stored_to(id)
      OutboundMessage.connection.select_value(
        OutboundMessage.sanitize_sql(["SELECT \"to\" FROM outbound_messages WHERE id = ?", id])
      )
    end

    it "grava o telefone cifrado, lê de volta e acha por igualdade" do
      msg = make_outbound("5541999990003")

      expect(stored_to(msg.id)).not_to include("5541999990003")
      expect(ActiveRecord::Encryption.encryptor.encrypted?(stored_to(msg.id))).to be(true)
      expect(OutboundMessage.find(msg.id).to).to eq("5541999990003")
      expect(OutboundMessage.where(to: "5541999990003").count).to eq(1)
    end

    it "não casa o mesmo telefone gravado por outra cidade" do
      make_outbound("5541999990004")

      expect(CityConnection.with(TEST_CITY_B) { OutboundMessage.where(to: "5541999990004").count }).to eq(0)
    end
  end
end
