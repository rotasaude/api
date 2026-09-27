require "rails_helper"

# F-07.7 (ADR-0020; fechamento do módulo 07): só o worker cria e apaga banco de
# cidade. A credencial de rota_provisioner vai SÓ para o papel worker do Kamal —
# nem para o web, nem para o env global, nem para acessório. E os papéis de
# plataforma nascem com os atributos que o provisionamento pressupõe.
RSpec.describe "Credencial e papéis de provisionamento (F-07.7)" do
  %w[development production].each do |env|
    context "deploy/#{env}/deploy.yml" do
      let(:config) { YAML.load_file(Rails.root.join("deploy/#{env}/deploy.yml")) }

      def names(env_block)
        return [] if env_block.nil?

        Array(env_block["secret"]) + (env_block["clear"] || {}).keys
      end

      it "entrega PROVISIONER_DATABASE_URL ao papel worker" do
        expect(names(config.dig("servers", "worker", "env"))).to include("PROVISIONER_DATABASE_URL")
      end

      it "não entrega PROVISIONER_DATABASE_URL a nenhum outro papel, ao env global nem a acessório" do
        others = config.fetch("servers").except("worker").values.flat_map { |role| names(role.is_a?(Hash) ? role["env"] : nil) }
        accessories = (config["accessories"] || {}).values.flat_map { |acc| names(acc["env"]) }

        expect(others).not_to include("PROVISIONER_DATABASE_URL")
        expect(names(config["env"])).not_to include("PROVISIONER_DATABASE_URL")
        expect(accessories).not_to include("PROVISIONER_DATABASE_URL")
      end
    end
  end

  describe "papéis de plataforma no cluster (platform:bootstrap)" do
    def role(name)
      PlatformRecord.connection.select_one(<<~SQL)
        SELECT rolsuper, rolinherit, rolcreatedb, rolcreaterole, rolcanlogin
        FROM pg_roles WHERE rolname = #{PlatformRecord.connection.quote(name)}
      SQL
    end

    it "cria rota_provisioner com CREATEDB, CREATEROLE e INHERIT, nunca superusuário" do
      expect(role("rota_provisioner")).to include(
        "rolsuper" => false, "rolinherit" => true, "rolcreatedb" => true,
        "rolcreaterole" => true, "rolcanlogin" => true
      )
    end

    it "cria rota_platform sem superusuário nem poder de criar banco ou papel" do
      expect(role("rota_platform")).to include(
        "rolsuper" => false, "rolcreatedb" => false, "rolcreaterole" => false, "rolcanlogin" => true
      )
    end
  end
end
