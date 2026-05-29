from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    # General
    deployment_version: str = "dev"
    pod_name: str = "unknown"
    namespace: str = "default"
    node_name: str = "unknown"
    service_name: str = "api-service"

    # OTel
    otel_exporter_otlp_endpoint: str = "http://otel-collector.observability.svc.cluster.local:4317"
    otel_traces_sampler_arg: float = 1.0

    # Azure resources
    azure_tenant_id: str = ""
    azure_client_id: str = ""  # workload identity client id (UAMI)
    speech_endpoint: str = ""
    speech_region: str = "eastus"
    openai_endpoint: str = ""
    openai_chat_deployment: str = "gpt-4o-mini"
    openai_api_version: str = "2024-08-01-preview"
    cosmos_endpoint: str = ""
    cosmos_database: str = "orders"
    cosmos_container: str = "voice-orders"
    cosmos_incidents_container: str = "IncidentHistory"
    servicebus_fqdn: str = ""
    servicebus_queue: str = "voice-orders"
    redis_host: str = ""
    redis_port: int = 6380
    third_party_api_url: str = "https://uselessfacts.jsph.pl/api/v2/facts/random"

    # Fault toggles (read at request time so they can be flipped via /admin/faults)
    fault_force_openai_down: bool = False
    fault_force_speech_down: bool = False
    fault_force_thirdparty_down: bool = False
    fault_force_cosmos_dns_break: bool = False
    fault_extra_cpu_burn_ms: int = 0
    fault_force_exception: bool = False
    # Fires 20 parallel Cosmos writes per request to exhaust 400 RU budget → 429s
    fault_cosmos_throttle: bool = False


settings = Settings()
