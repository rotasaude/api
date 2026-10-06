# National business days for the competence deadline (spec §6.5). Fixed
# holidays and Easter-based movable ones; Carnaval and Corpus Christi are
# federal optional days and count as non-business, so the estimate can fall
# one day before the official date (see config/ledi/siaps_deadlines.yml).
module Ledi
  module BusinessCalendar
    FIXED = [ [ 1, 1 ], [ 4, 21 ], [ 5, 1 ], [ 9, 7 ], [ 10, 12 ], [ 11, 2 ], [ 11, 15 ], [ 11, 20 ], [ 12, 25 ] ].freeze
    EASTER_OFFSETS = [ -48, -47, -2, 60 ].freeze # Carnaval (Mon, Tue), Good Friday, Corpus Christi

    module_function

    def holidays(year)
      @holidays ||= {}
      @holidays[year] ||= begin
        easter_day = easter(year)
        (FIXED.map { |m, d| Date.new(year, m, d) } + EASTER_OFFSETS.map { |o| easter_day + o }).to_set.freeze
      end
    end

    def business_day?(date)
      !(date.saturday? || date.sunday?) && !holidays(date.year).include?(date)
    end

    # Anonymous Gregorian algorithm (Meeus/Jones/Butcher).
    def easter(year)
      a = year % 19
      b, c = year.divmod(100)
      d, e = b.divmod(4)
      f = (b + 8) / 25
      g = (b - f + 1) / 3
      h = (19 * a + b - d - g + 15) % 30
      i, k = c.divmod(4)
      l = (32 + 2 * e + 2 * i - h - k) % 7
      m = (a + 11 * h + 22 * l) / 451
      month, day = (h + l - 7 * m + 114).divmod(31)
      Date.new(year, month, day + 1)
    end
  end
end
