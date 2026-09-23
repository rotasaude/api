# Identidade DECLARADA do cidadão no canal web (spec 2026-09-22-web-citizen-
# channel §2): o CPF só passa pela conta do dígito verificador, e o celular só
# pelo formato. Quem prova posse do celular é o OTP; quem prova o CPF é a
# validação presencial (subprojeto 2).
module CitizenIdentity
  module Cpf
    module_function

    def normalize(input)
      digits = input.to_s.gsub(/\D/, "")
      return nil unless digits.length == 11
      return nil if digits.chars.uniq.size == 1
      return nil unless check_digits_ok?(digits)

      digits
    end

    def mask(digits)
      "***.#{digits[3, 3]}.#{digits[6, 3]}-**"
    end

    def check_digits_ok?(digits)
      nums = digits.chars.map(&:to_i)
      first = check_digit(nums[0, 9])
      second = check_digit(nums[0, 9] + [first])
      nums[9] == first && nums[10] == second
    end

    def check_digit(nums)
      start = nums.size + 1
      sum = nums.each_with_index.sum { |n, i| n * (start - i) }
      rest = (sum * 10) % 11
      rest == 10 ? 0 : rest
    end
  end

  module Phone
    module_function

    # Celular brasileiro: DDD (dois dígitos de 1 a 9) + 9 + oito dígitos.
    MOBILE = /\A[1-9][1-9]9\d{8}\z/

    def normalize(input)
      digits = input.to_s.gsub(/\D/, "")
      digits = digits[2..] if digits.length == 13 && digits.start_with?("55")
      return nil unless digits.match?(MOBILE)

      "+55#{digits}"
    end

    def mask(e164)
      "(**) *****-#{e164.to_s[-4..]}"
    end
  end
end
