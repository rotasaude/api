# Resolve host → City. Lê o catálogo de plataforma e mantém um cache em
# processo, porque isso roda antes de toda requisição.
#
# Subdomínios reservados não são cidades: pertencem à plataforma.
class CityCatalog
  RESERVED = %w[admin api auth www].freeze

  class << self
    def find_by_host(host)
      label = label_for(host)
      return nil if label.nil? || RESERVED.include?(label)

      cache.fetch(label) { cache[label] = City.find_by(slug: label) }
    end

    def reserved_host?(host)
      RESERVED.include?(label_for(host))
    end

    def reset_cache!
      @cache = {}
    end

    private

    def cache
      @cache ||= {}
    end

    def label_for(host)
      return nil if host.blank?
      host.to_s.split(":").first.to_s.split(".").first.presence&.downcase
    end
  end
end
