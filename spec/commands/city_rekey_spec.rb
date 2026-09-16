require "rails_helper"

# Não dá para reusar o ReencryptionJob: ele chama record.encrypt, que lê e
# escreve no MESMO contexto; e o provedor determinístico não aceita duas chaves.
#
# Cada exemplo aqui usa DUAS materiais de chave distintas (a "antiga", material
# arbitrário injetado via `with_material`, e a "nova", o encryption_key real da
# `city` criada pela factory) e prova a DIREÇÃO da troca: ilegível sob a
# material antiga depois do rekey, legível sob a nova — e, para o atributo
# determinístico, que a busca pelo valor em claro ainda acha a linha (e que a
# busca com a material antiga NÃO acha mais, provando que o índice também virou).
RSpec.describe CityRekey do
  let!(:city) { create(:city, database_url: city_database_url("rota_saude_test_city_a")) }

  def with_material(material, &block)
    other = City.new(slug: city.slug, name: city.name, status: city.status,
                     database_url: city.database_url, encryption_key: material)
    CityConnection.with(city) do
      Current.set(city: other) do
        ActiveRecord::Encryption.with_encryption_context(**CityEncryption.context_properties(other), &block)
      end
    end
  end

  it "rewrites rows so they are unreadable under the old material and readable under the city's own" do
    old_material = "0" * 64
    convo = with_material(old_material) { Conversation.create!(phone: "+5541988880001", state: :greeting) }

    result = CityRekey.call(city: city, from_key: old_material)

    expect(result).to be_ok
    expect(result.payload[:counts]["Conversation"]).to be >= 1

    # Legível sob a chave nova (a material real da cidade).
    expect(CityConnection.with(city) { Conversation.find(convo.id).phone }).to eq("+5541988880001")

    # Ilegível sob a chave antiga: o ciphertext gravado agora é outro.
    expect {
      with_material(old_material) { Conversation.find(convo.id).phone }
    }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
  end

  it "makes the deterministic lookup work under the new material and stop matching the old" do
    old_material = "0" * 64
    with_material(old_material) { Conversation.create!(phone: "+5541988880002", state: :greeting) }

    CityRekey.call(city: city, from_key: old_material)

    # A busca determinística pelo valor em claro, sob a chave nova, acha a linha.
    expect(CityConnection.with(city) { Conversation.where(phone: "+5541988880002").count }).to eq(1)

    # A mesma busca, sob a chave antiga, não acha mais nada: o ciphertext do
    # índice determinístico também foi reescrito.
    expect(with_material(old_material) { Conversation.where(phone: "+5541988880002").count }).to eq(0)
  end

  it "fails when a row cannot be read under the source material" do
    CityConnection.with(city) do
      InboundMessage.create!(message_id: "wamid-#{SecureRandom.hex(4)}", from: "+5541988880009",
                             kind: "text", raw: '{"t":"x"}')
    end

    result = CityRekey.call(city: city, from_key: "9" * 64)

    expect(result).to be_failure
    expect(result.reason).to eq(:unreadable)
  end
end
