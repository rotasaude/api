require "base64"

# Cursor composto e opaco da linha do tempo (contrato §3): o instante com
# microssegundos, o kind e o id da origem da última entrada da página.
module Timeline
  Cursor = Data.define(:at, :kind, :id) do
    const_set(:Invalid, Class.new(StandardError))
    const_set(:UUID, /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    const_set(:INSTANT, /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{6}Z\z/)

    def self.encode(entry)
      Base64.urlsafe_encode64("#{entry.occurred_at.utc.iso8601(6)}|#{entry.kind}|#{entry.source_id}", padding: false)
    end

    def self.decode(raw)
      return nil if raw.nil? || raw == ""
      raise self::Invalid unless raw.is_a?(String)

      at, kind, id = Base64.urlsafe_decode64(raw).split("|", 3)
      raise self::Invalid unless at.to_s.match?(self::INSTANT) && Timeline::KINDS.include?(kind) && id.to_s.match?(self::UUID)

      new(at: Time.iso8601(at), kind: kind, id: id.downcase)
    rescue ArgumentError
      raise self::Invalid
    end
  end
end
