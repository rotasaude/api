require "rails_helper"

# Spec da API de manutenção §5: a rota só é desenhada em development e staging,
# com a chave ligada — e em produção a chave ligada DERRUBA o boot. A decisão é
# uma função pura porque a ausência da rota em produção precisa ser provável por
# spec, e a suíte roda em test.
RSpec.describe MaintenanceApi do
  describe ".enabled?" do
    it "is true in development and staging only with the flag on" do
      expect(described_class.enabled?(env: "development", flag: "true")).to be(true)
      expect(described_class.enabled?(env: "staging", flag: "true")).to be(true)
      expect(described_class.enabled?(env: "development", flag: nil)).to be(false)
      expect(described_class.enabled?(env: "staging", flag: "false")).to be(false)
    end

    it "is never true in production, whatever the flag says" do
      expect(described_class.enabled?(env: "production", flag: "true")).to be(false)
      expect(described_class.enabled?(env: "production", flag: nil)).to be(false)
    end

    it "is always true in test, where the request specs live" do
      expect(described_class.enabled?(env: "test", flag: nil)).to be(true)
    end
  end

  describe ".check_boot!" do
    it "refuses to boot production with the flag on" do
      expect { described_class.check_boot!(env: "production", flag: "true") }
        .to raise_error(MaintenanceApi::EnabledInProduction, /MAINTENANCE_API_ENABLED/)
    end

    it "lets every other combination boot" do
      [ %w[production false], %w[staging true], %w[development true], %w[test false] ].each do |env, flag|
        expect { described_class.check_boot!(env: env, flag: flag, origin: "https://maintenance.example") }
          .not_to raise_error
      end
    end

    # I3 (fix round 2): a trava de CSRF é a igualdade com MAINTENANCE_FRONTEND_ORIGIN.
    # Vazia, ela falha fechada — a API sobe recusando tudo com 403, e o sintoma
    # não aponta para a variável que falta. Em ambiente publicado isso é erro de
    # deploy, e erro de deploy aparece no deploy.
    it "refuses to boot a deployed environment with the API on and no frontend origin" do
      [ nil, "", "   " ].each do |origin|
        expect { described_class.check_boot!(env: "staging", flag: "true", origin: origin) }
          .to raise_error(MaintenanceApi::MissingFrontendOrigin, /MAINTENANCE_FRONTEND_ORIGIN/)
      end
    end

    it "does not ask for the origin where the API is off, or outside a deployed environment" do
      expect { described_class.check_boot!(env: "staging", flag: nil, origin: nil) }.not_to raise_error
      expect { described_class.check_boot!(env: "development", flag: "true", origin: nil) }.not_to raise_error
      expect { described_class.check_boot!(env: "test", flag: nil, origin: nil) }.not_to raise_error
    end
  end
end
