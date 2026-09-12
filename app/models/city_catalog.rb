# Resolve host → City. Lê o catálogo de plataforma e mantém um cache em
# processo, porque isso roda antes de toda requisição.
#
# Subdomínios reservados não são cidades: pertencem à plataforma.
#
# O cache NUNCA memoiza miss (nil): fazer isso deixaria uma cidade em
# provisionamento presa em 404 para sempre num processo já quente. Todo hit
# expira depois de CACHE_TTL, para que suspensão/reativação convirjam sem
# reiniciar processos — sem isso, suspender uma cidade não tira ela do ar até
# o próximo deploy. E o mapa tem um teto (MAX_CACHE_ENTRIES): a chave é um
# label de host não autenticado e controlado pelo atacante.
class CityCatalog
  RESERVED = %w[admin api auth www].freeze
  CACHE_TTL = 30 # seconds
  MAX_CACHE_ENTRIES = 500

  class << self
    def find_by_host(host)
      label = label_for(host)
      return nil if label.nil? || RESERVED.include?(label)

      fresh = cache[label]
      return fresh[:city] if fresh && !expired?(fresh)

      city = City.find_by(slug: label)
      store(label, city) if city
      city
    end

    def reserved_host?(host)
      RESERVED.include?(label_for(host))
    end

    def reset_cache!
      @cache = {}
    end

    private

    def store(label, city)
      # Bound the map before inserting: evict the oldest entry (Ruby hashes
      # preserve insertion order) rather than let an unauthenticated,
      # attacker-controlled set of host labels grow it without limit.
      cache.delete(cache.each_key.first) if cache.size >= MAX_CACHE_ENTRIES && !cache.key?(label)
      cache[label] = { city: city, expires_at: now + CACHE_TTL }
    end

    def expired?(entry)
      entry[:expires_at] <= now
    end

    def now
      Time.current.to_f
    end

    def cache
      @cache ||= {}
    end

    def label_for(host)
      return nil if host.blank?
      host.to_s.split(":").first.to_s.split(".").first.presence&.downcase
    end
  end
end
