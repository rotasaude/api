require "rails_helper"
require "prism"

# Guarda do invariante da Ruling R18: nenhum PlatformEvent (banco de PLATAFORMA)
# carrega dado pessoal. Falha se um payload tiver chave email, cpf, provider_uid,
# phone, from, wa_id, name ou body — em qualquer profundidade —, e se um call site
# de Platform.audit voltar a auditar evento que não é de plataforma ou a passar
# uma dessas chaves.
RSpec.describe "PlatformEvent payload guard (Ruling R18)" do
  R18_FORBIDDEN_PAYLOAD_KEYS = %w[email cpf provider_uid phone from wa_id name body].freeze
  R18_PLATFORM_EVENT_NAMES = %w[municipality.provisioned channel.token_rotated channel.unknown_seen].freeze

  it "forbids exactly the keys the ruling names" do
    expect(PlatformEvent::FORBIDDEN_PAYLOAD_KEYS).to match_array(R18_FORBIDDEN_PAYLOAD_KEYS)
  end

  R18_FORBIDDEN_PAYLOAD_KEYS.each do |key|
    it "refuses a top-level #{key} key and writes nothing" do
      expect {
        expect { Platform.audit("channel.token_rotated", key.to_sym => "x") }
          .to raise_error(ActiveRecord::RecordInvalid) { |e| expect(e.record.errors[:payload].join).to include(key) }
      }.not_to change(PlatformEvent, :count)
    end

    it "refuses a #{key} key nested inside the payload" do
      expect { Platform.audit("channel.unknown_seen", sample: [ { "meta" => { key => "x" } } ]) }
        .to raise_error(ActiveRecord::RecordInvalid) { |e| expect(e.record.errors[:payload].join).to include(key) }
    end
  end

  it "matches keys case-insensitively" do
    expect { Platform.audit("channel.unknown_seen", "Email" => "someone@example.com") }
      .to raise_error(ActiveRecord::RecordInvalid)
  end

  it "accepts the payload shapes of the three platform events" do
    city_id = SecureRandom.uuid
    expect {
      Platform.audit("municipality.provisioned", city_id: city_id, ibge_code: "4106902", by: SecureRandom.uuid)
      Platform.audit("channel.token_rotated", city_id: city_id, phone_number_id: "PNID-1", by: SecureRandom.uuid)
      Platform.audit("channel.unknown_seen", phone_number_id: "PNID-2", hits: 1)
    }.to change(PlatformEvent, :count).by(3)
  end

  describe "Platform.audit call sites in app/ and lib/" do
    def audit_calls
      Dir[Rails.root.join("{app,lib}/**/*.{rb,rake}").to_s].flat_map do |file|
        found = []
        walk = lambda do |node|
          if node.is_a?(Prism::CallNode) && node.name.to_sym == :audit &&
             node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name.to_sym == :Platform
            found << [ file, node ]
          end
          node.compact_child_nodes.each { |child| walk.call(child) }
        end
        walk.call(Prism.parse_file(file).value)
        found
      end
    end

    it "audit only platform events and pass no forbidden payload key" do
      calls = audit_calls
      expect(calls).not_to be_empty

      calls.each do |file, call|
        where = "#{file.delete_prefix("#{Rails.root}/")}:#{call.location.start_line}"
        args = call.arguments&.arguments || []

        event = args.first
        expect(event).to be_a(Prism::StringNode), "#{where}: event name must be a string literal"
        expect(R18_PLATFORM_EVENT_NAMES).to include(event.unescaped),
          "#{where}: #{event.unescaped} is not a platform event (Ruling R18)"

        keys = args.grep(Prism::KeywordHashNode).flat_map(&:elements).grep(Prism::AssocNode).map do |assoc|
          assoc.key.respond_to?(:unescaped) ? assoc.key.unescaped : assoc.key.slice
        end
        expect(keys.map(&:downcase) & R18_FORBIDDEN_PAYLOAD_KEYS).to be_empty,
          "#{where}: forbidden payload key(s) #{keys}"
      end
    end
  end
end
