require "rails_helper"
require "prism"

# Guarda do invariante da Ruling R18: nenhum PlatformEvent (banco de PLATAFORMA)
# carrega dado pessoal. Falha se um payload tiver chave que CONTENHA email, cpf,
# provider_uid, phone, wa_id, body ou name, ou que SEJA from — em qualquer
# profundidade, salvo a allow-list (phone_number_id, city_name) —, e se um call
# site de Platform.audit voltar a auditar evento que não é de plataforma ou a
# passar uma dessas chaves.
RSpec.describe "PlatformEvent payload guard (Ruling R18)" do
  R18_FORBIDDEN_PAYLOAD_KEYS = %w[email cpf provider_uid phone from wa_id name body].freeze
  R18_FORBIDDEN_KEY_FRAGMENTS = %w[email cpf provider_uid phone wa_id body name].freeze
  R18_FORBIDDEN_EXACT_KEYS = %w[from].freeze
  R18_ALLOWED_PAYLOAD_KEYS = %w[phone_number_id city_name].freeze
  R18_PLATFORM_EVENT_NAMES = %w[municipality.provisioned channel.token_rotated channel.unknown_seen operator.login operator.city_access].freeze

  # Independent restatement of the rule (not PlatformEvent's own method), so the
  # static call-site check below cannot drift together with the model.
  R18_FORBIDDEN_KEY = lambda do |key|
    key = key.to_s.downcase
    !R18_ALLOWED_PAYLOAD_KEYS.include?(key) &&
      (R18_FORBIDDEN_EXACT_KEYS.include?(key) || R18_FORBIDDEN_KEY_FRAGMENTS.any? { |f| key.include?(f) })
  end

  it "forbids exactly the keys the ruling names" do
    expect(PlatformEvent::FORBIDDEN_PAYLOAD_KEYS).to match_array(R18_FORBIDDEN_PAYLOAD_KEYS)
    expect(PlatformEvent::FORBIDDEN_KEY_FRAGMENTS).to match_array(R18_FORBIDDEN_KEY_FRAGMENTS)
    expect(PlatformEvent::FORBIDDEN_EXACT_KEYS).to match_array(R18_FORBIDDEN_EXACT_KEYS)
    expect(PlatformEvent::ALLOWED_PAYLOAD_KEYS).to match_array(R18_ALLOWED_PAYLOAD_KEYS)
  end

  # M2 (review 5b) and re-review: the exact-name match let these through.
  %w[user_email admin_email phone_number display_phone_number full_name display_name username].each do |key|
    it "refuses #{key} (contains a forbidden fragment), top-level and nested" do
      expect {
        expect { Platform.audit("channel.token_rotated", key.to_sym => "x") }
          .to raise_error(ActiveRecord::RecordInvalid) { |e| expect(e.record.errors[:payload].join).to include(key) }
      }.not_to change(PlatformEvent, :count)

      expect { Platform.audit("channel.unknown_seen", sample: [ { "meta" => { key => "x" } } ]) }
        .to raise_error(ActiveRecord::RecordInvalid) { |e| expect(e.record.errors[:payload].join).to include(key) }
    end
  end

  %w[phone_number_id city_name city_id].each do |key|
    it "accepts #{key}, top-level and nested" do
      expect {
        Platform.audit("channel.token_rotated", key.to_sym => "x")
        Platform.audit("channel.unknown_seen", sample: [ { "meta" => { key => "x" } } ])
      }.to change(PlatformEvent, :count).by(2)
    end
  end

  it "keeps from as an exact match (from_state passes)" do
    expect {
      Platform.audit("channel.unknown_seen", from_state: "x")
    }.to change(PlatformEvent, :count).by(1)
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
        expect(keys.select { |k| R18_FORBIDDEN_KEY.call(k) }).to be_empty,
          "#{where}: forbidden payload key(s) #{keys}"
      end
    end
  end
end
