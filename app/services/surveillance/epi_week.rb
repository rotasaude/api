# Semana epidemiológica do Sinan (módulo 25): domingo a sábado; a semana 1 do
# ano é a que contém 4 de janeiro, então algumas semanas 1 começam ainda em
# dezembro e alguns anos têm a semana 53. Ruby puro, sem banco: quem chama
# passa a data local da cidade (EpiWeek.current(today)); aqui não se lê
# Current.city.
module Surveillance
  EpiWeek = Data.define(:year, :week) do
    include Comparable

    FORMAT = /\A(\d{4})-(\d{2})\z/

    class << self
      # Domingo da semana que contém 4 de janeiro de `year` (início da SE 1).
      def start_of(year)
        d = Date.new(year, 1, 4)
        d - d.wday
      end

      # Quantas semanas o ano tem (52 ou 53).
      def weeks_in(year)
        (start_of(year + 1) - start_of(year)).to_i / 7
      end

      def for(date)
        year = [ date.year + 1, date.year, date.year - 1 ].find { |y| start_of(y) <= date }
        new(year: year, week: (date - start_of(year)).to_i / 7 + 1)
      end

      def current(today = Time.zone.today)
        self.for(today)
      end

      # "YYYY-WW" -> EpiWeek; nil para texto malformado ou semana inexistente.
      def parse(string)
        return nil unless string.is_a?(String)

        match = FORMAT.match(string)
        return nil unless match

        year = match[1].to_i
        week = match[2].to_i
        return nil unless week.between?(1, weeks_in(year))

        new(year: year, week: week)
      end

      # Do `from` ao `to`, inclusive, em ordem crescente; vazio se from > to.
      def between(from, to)
        weeks = []
        week = from
        while week <= to
          weeks << week
          week = week.succ
        end
        weeks
      end
    end

    def to_s
      format("%04d-%02d", year, week)
    end

    def starts_on
      self.class.start_of(year) + (week - 1) * 7
    end

    def ends_on
      starts_on + 6
    end

    def range
      starts_on..ends_on
    end

    def succ
      self.class.for(starts_on + 7)
    end

    def pred
      self.class.for(starts_on - 7)
    end

    # A semana n semanas antes.
    def -(count)
      self.class.for(starts_on - count * 7)
    end

    def <=>(other)
      return nil unless other.is_a?(self.class)

      [ year, week ] <=> [ other.year, other.week ]
    end
  end
end
