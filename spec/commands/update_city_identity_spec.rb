require "rails_helper"

RSpec.describe UpdateCityIdentity do
  include CoatOfArmsHelpers

  let(:city) { create(:city) }

  def upload(bytes) = coat_upload(bytes)

  it "devolve a lista ordenada do que mudou" do
    result = described_class.call(city: city, health_department_name: "Secretaria", coat_of_arms: upload(coat_png(512, 512)))
    expect(result).to be_ok
    expect(result.payload[:changed]).to eq(%w[coat_of_arms health_department_name])
  end

  it "mesmo nome de novo: nada mudou" do
    described_class.call(city: city, health_department_name: "Secretaria")
    result = described_class.call(city: city, health_department_name: "Secretaria")
    expect(result.payload[:changed]).to eq([])
  end

  it "remover sem brasão não muda nada" do
    expect(described_class.call(city: city, remove_coat_of_arms: true).payload[:changed]).to eq([])
  end

  it "falha com a razão do check e não grava o nome enviado junto" do
    result = described_class.call(city: city, health_department_name: "Secretaria", coat_of_arms: upload("GIF89a".b))
    expect(result.reason).to eq(:invalid_format)
    expect(city.reload.health_department_name).to be_nil
  end

  it "só o upload inválido não deixa blob órfão" do
    expect { described_class.call(city: city, coat_of_arms: upload(coat_png(10, 10))) }.not_to change(ActiveStorage::Blob, :count)
  end

  describe "falhas na escrita" do
    before { described_class.call(city: city, coat_of_arms: upload(coat_png(512, 512))) }

    it "se o attach falha, a cidade mantém o brasão anterior e o blob novo é purgado" do
      old_key = city.reload.coat_of_arms.blob.key
      allow_any_instance_of(ActiveStorage::Attached::One).to receive(:attach).and_raise(RuntimeError, "boom")

      expect do
        expect { described_class.call(city: city, health_department_name: "Nova", coat_of_arms: upload(coat_png(256, 256))) }
          .to raise_error(RuntimeError, "boom")
      end.not_to change(ActiveStorage::Blob, :count)

      fresh = City.find(city.id)
      expect(fresh.coat_of_arms).to be_attached
      expect(fresh.coat_of_arms.blob.key).to eq(old_key)
      expect(fresh.health_department_name).to be_nil
    end

    it "se purgar o blob antigo falha, a troca vale e nada estoura" do
      allow_any_instance_of(ActiveStorage::Blob).to receive(:purge).and_raise(RuntimeError, "s3 down")
      old_checksum = city.reload.coat_of_arms.blob.checksum

      result = described_class.call(city: city, coat_of_arms: upload(coat_png(256, 256)))

      expect(result).to be_ok
      expect(result.payload[:changed]).to eq(%w[coat_of_arms])
      expect(City.find(city.id).coat_of_arms.blob.checksum).not_to eq(old_checksum)
    end

    it "só o nome mudou: o audit não leva o checksum do brasão" do
      described_class.call(city: city, health_department_name: "Secretaria")
      ev = PlatformEvent.where(name: "city.identity_updated").order(:created_at).last
      expect(ev.payload["fields"]).to eq(%w[health_department_name])
      expect(ev.payload).not_to have_key("coat_of_arms_checksum")
    end
  end
end
