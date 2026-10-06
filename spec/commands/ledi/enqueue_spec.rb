require "rails_helper"

RSpec.describe Ledi::Enqueue do
  let(:city) { register_test_city! }
  let(:ficha) do
    Ledi::Fichas::Synthetic.new(cnes: "1234567", ine: "0000123456", professional_cns: "700000000000005",
                                cbo: "225142", attended_at: Time.current)
  end

  before do
    ledi_ready!(city, pec_url: "https://pec.a.test")
    allow(Ledi::DeliverJob).to receive(:perform_later)
  end

  it "grava a ficha serializada e cifrada, pendente para agora, e dispara o envio" do
    entry = described_class.call(ficha, city: city)

    expect(entry).to have_attributes(status: "pending", ficha_type: "procedimento", competence: ficha.competence,
                                     source_type: "synthetic", source_id: ficha.source_id, ledi_version: "8.7.0",
                                     attempts: 0)
    expect(entry.uuid).to match(/\A1234567-\h{8}-\h{4}-4\h{3}-\h{4}-\h{12}\z/)
    expect(entry.uuid.length).to eq(44)
    expect(entry.next_attempt_at).to be <= Time.current
    expect(Ledi::Transport.read(entry.bytes).uuidDadoSerializado).to eq(entry.uuid)
    expect(Ledi::DeliverJob).to have_received(:perform_later).with(no_args)
  end

  it "a mesma fonte não entra duas vezes" do
    first = described_class.call(ficha, city: city)
    expect(described_class.call(ficha, city: city).id).to eq(first.id)
    expect(LediOutboxEntry.count).to eq(1)
  end

  it "interruptor desligado ou record_mode off: nada entra" do
    ledi_off!(city)
    expect(described_class.call(ficha, city: city)).to be_nil
    ledi_ready!(city, pec_url: "https://pec.a.test", record_mode: "off")
    expect(described_class.call(ficha, city: city)).to be_nil
    expect(LediOutboxEntry.count).to eq(0)
    expect(Ledi::DeliverJob).not_to have_received(:perform_later)
  end

  # R35: Current.city vem do CityCatalog (cache de ~30 s); o record_mode é relido.
  it "record_mode desligado há pouco (cidade em memória ainda diz integrated): nada entra" do
    City.where(id: city.id).update_all(record_mode: "off")
    expect(city.record_mode).to eq("integrated")
    expect(described_class.call(ficha, city: city)).to be_nil
    expect(LediOutboxEntry.count).to eq(0)
  end

  it "ficha fora da interface: Ledi::Ficha::Invalid, nada gravado" do
    expect { described_class.call(Object.new, city: city) }.to raise_error(Ledi::Ficha::Invalid)
    expect(LediOutboxEntry.count).to eq(0)
  end
end
