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
end
