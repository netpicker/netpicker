# NetPicker Development Container

This devcontainer configuration provides a complete development environment for the NetPicker project using your existing Docker Compose setup.

## What's Included

- **Development Environment**: Uses the `api` service from your docker-compose.yml as the development container
- **All Services**: Automatically starts all NetPicker services (database, Redis, frontend, etc.)
- **Development Tools**:
  - Python 3.11 with development tools
  - Node.js 18 with npm/yarn
  - Git with Oh My Zsh shell
  - Docker CLI for container management
  - VS Code extensions for Python, Docker, YAML, and more

## Getting Started

1. **Prerequisites**:

   - VS Code with the "Dev Containers" extension installed
   - Docker Desktop running on your machine

2. **Open in Container**:

   - Open this project in VS Code
   - Press `Ctrl+Shift+P` (or `Cmd+Shift+P` on Mac)
   - Type "Dev Containers: Reopen in Container"
   - Select the command and wait for the container to build

3. **First Time Setup**:
   - The container will automatically install Python development dependencies
   - All services will start automatically (database, Redis, API, frontend, etc.)

## Available Services

Once the devcontainer is running, you'll have access to:

- **API Server**: http://localhost:8000
- **Frontend**: http://localhost:80
- **Swagger UI**: Available through the frontend
- **Database**: PostgreSQL running in the `db` container
- **Redis**: Cache/message broker in the `redis` container

## Port Forwarding

The following ports are automatically forwarded:

- `8000`: API Server
- `80`: Frontend
- `5514`: Syslog UDP
- `6601`: Syslog TCP
- `6514`: Syslog Secure TCP

## Development Workflow

1. **Code Editing**: Your workspace is mounted at `/workspace` in the container
2. **Running Tests**: Use the integrated terminal to run pytest or other commands
3. **API Development**: The API service runs in development mode with your code changes
4. **Database Access**: Connect to PostgreSQL using the credentials in docker-compose.yml

## Customization

- **Extensions**: Modify the `extensions` array in `devcontainer.json`
- **Settings**: Update VS Code settings in the `customizations.vscode.settings` section
- **Environment**: Add environment variables in `docker-compose.override.yml`
- **Dependencies**: Modify the `postCreateCommand` to install additional packages

## Troubleshooting

- **Container not starting**: Check Docker Desktop is running and you have enough resources
- **Port conflicts**: Ensure ports 8000 and 80 are not in use on your host machine
- **Permission issues**: The container runs as the `vscode` user with UID 1000

## Files

- `devcontainer.json`: Main devcontainer configuration
- `docker-compose.override.yml`: Development-specific Docker Compose overrides
- `README.md`: This file
