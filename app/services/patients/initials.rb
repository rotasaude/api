# Iniciais do paciente (ADR 0033, conferência pública /v; card rotasaude/api#51,
# lista de rascunhos órfãos): uma letra por palavra, sem as partículas — o
# bastante para conferir, nunca o nome.
module Patients
  module Initials
    PARTICLES = %w[da das de do dos e].freeze

    module_function

    def call(name)
      name.to_s.split.reject { |word| PARTICLES.include?(word.downcase) }.map { |word| "#{word[0].upcase}." }.join
    end
  end
end
