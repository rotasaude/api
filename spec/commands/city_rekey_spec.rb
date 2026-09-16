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
  include ActiveSupport::Testing::TimeHelpers

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

  # Simula dado escrito ANTES do Plano 7: a chave GLOBAL da plataforma (não
  # nenhuma derivada de cidade), pelos mesmos dois mecanismos que
  # `CityRekey#in_platform_source` usa para LER esse dado (contexto com
  # PlatformKeyProvider para o atributo não-determinístico, flag em Current
  # para o determinístico).
  def with_platform_material(&block)
    CityConnection.with(city) do
      Current.set(deterministic_key_source: :platform) do
        ActiveRecord::Encryption.with_encryption_context(key_provider: PlatformKeyProvider.new, &block)
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

  # Fix round 1: sem uma transação por cima da reescrita inteira, uma falha na
  # metade deixava linhas já reescritas na chave nova e o resto na antiga —
  # e um retry contra a mesma cidade abortava de novo no primeiro registro já
  # migrado. Este exemplo prova tudo-ou-nada: a Conversation processada ANTES
  # da linha ilegível (TARGETS lista Conversation antes de InboundMessage) tem
  # que continuar exatamente como estava, não só "resultado é failure".
  it "rolls back everything when a later row fails, so nothing moves" do
    old_material = "0" * 64
    convo = with_material(old_material) { Conversation.create!(phone: "+5541988880010", state: :greeting) }

    # Escrita com a material REAL da cidade (não old_material) de propósito:
    # quando o rekey pedir from_key: old_material, essa linha é a que não lê.
    poison = CityConnection.with(city) do
      InboundMessage.create!(message_id: "wamid-#{SecureRandom.hex(4)}", from: "+5541988880011",
                             kind: "text", raw: '{"t":"poison"}')
    end

    result = CityRekey.call(city: city, from_key: old_material)

    expect(result).to be_failure
    expect(result.reason).to eq(:unreadable)

    # A Conversation, reescrita em memória ANTES de bater na linha ilegível,
    # não migrou de fato: ainda legível sob a material antiga...
    expect(with_material(old_material) { Conversation.find(convo.id).phone }).to eq("+5541988880010")
    # ...e ainda ILEGÍVEL sob a material nova — se tivesse migrado (mesmo
    # parcialmente), isto teria decifrado sem erro.
    expect {
      CityConnection.with(city) { Conversation.find(convo.id).phone }
    }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)

    # A própria linha ilegível continua intacta, na material real da cidade.
    expect(CityConnection.with(city) { InboundMessage.find(poison.id).raw }).to eq('{"t":"poison"}')
  end

  # Fix round 1: `save!` bate updated_at por padrão. Numa rekey de cidade
  # inteira isso faria toda conversa "abandonada" parecer tocada agora
  # (SweepAbandonedConversationsJob e Admin::OverviewQuery filtram por
  # updated_at) — um efeito colateral puramente da reescrita de chave, não de
  # uma mudança de domínio real.
  it "does not bump updated_at" do
    old_material = "0" * 64
    convo = with_material(old_material) { Conversation.create!(phone: "+5541988880012", state: :greeting) }
    original_updated_at = with_material(old_material) { Conversation.find(convo.id).updated_at }

    travel 1.hour do
      result = CityRekey.call(city: city, from_key: old_material)
      expect(result).to be_ok
    end

    expect(CityConnection.with(city) { Conversation.find(convo.id).updated_at }).to eq(original_updated_at)
  end

  # Fix round 2: a migração real (curitiba, maringa) não troca uma chave de
  # cidade por outra — troca a chave GLOBAL, pré-Plano-7, pela derivada da
  # cidade. Confirmado ao vivo (só leitura) contra os dois bancos de dev antes
  # deste round: Conversation#phone e InboundMessage#raw levantam
  # Errors::Decryption sob o contexto normal de cidade hoje. Este exemplo
  # reproduz esse estado do zero e prova a migração de ponta a ponta, com um
  # atributo determinístico E um não-determinístico.
  describe "source: :platform" do
    it "rekeys rows written under the platform key end-to-end" do
      convo = with_platform_material { Conversation.create!(phone: "+5541988880030", state: :greeting) }
      msg = with_platform_material do
        InboundMessage.create!(message_id: "wamid-#{SecureRandom.hex(4)}", from: "+5541988880031",
                               kind: "text", raw: '{"t":"pre-migration"}')
      end

      # Estado real de hoje em curitiba/maringa: ilegível sob o contexto
      # normal da cidade, tanto o determinístico quanto o não-determinístico.
      expect {
        CityConnection.with(city) { Conversation.find(convo.id).phone }
      }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)
      expect {
        CityConnection.with(city) { InboundMessage.find(msg.id).raw }
      }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)

      result = CityRekey.call(city: city, source: :platform)

      expect(result).to be_ok
      expect(result.payload[:counts]["Conversation"]).to be >= 1
      expect(result.payload[:counts]["InboundMessage"]).to be >= 1

      # Legível sob o contexto normal da cidade, os dois atributos.
      expect(CityConnection.with(city) { Conversation.find(convo.id).phone }).to eq("+5541988880030")
      expect(CityConnection.with(city) { InboundMessage.find(msg.id).raw }).to eq('{"t":"pre-migration"}')

      # A busca determinística pelo valor em claro acha a linha.
      expect(CityConnection.with(city) { Conversation.where(phone: "+5541988880030").count }).to eq(1)

      # O ciphertext não decifra mais sob a chave da plataforma: migrou de
      # verdade, não só "ainda dá pra ler das duas formas".
      expect {
        with_platform_material { Conversation.find(convo.id).phone }
      }.to raise_error(ActiveRecord::Encryption::Errors::Decryption)

      # A flag não escapa: fora de uma cidade, leitura determinística continua
      # falhando fechado — se a flag tivesse ficado presa em :platform, isto
      # teria servido o provider global em vez de levantar MissingKey.
      expect {
        Current.set(city: nil) { CityDeterministicKeyProvider.new.encryption_key }
      }.to raise_error(CityEncryption::MissingKey)

      # E uma leitura normal, depois do rekey, ainda usa a material DA
      # CIDADE — se a flag tivesse escapado para :platform, esta Conversation
      # (cifrada com a chave derivada da cidade) teria saído ilegível.
      normal = CityConnection.with(city) { Conversation.create!(phone: "+5541988880032", state: :greeting) }
      expect(CityConnection.with(city) { Conversation.find(normal.id).phone }).to eq("+5541988880032")
    end

    it "rejects from_key: combined with source: :platform" do
      expect {
        CityRekey.call(city: city, from_key: "9" * 64, source: :platform)
      }.to raise_error(ArgumentError)
    end
  end
end
