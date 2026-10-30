vim9script

def g:LspConfig_pyright(): dict<any>
  return {
    name: 'pyright',
    filetype: ['python'],
    path: exepath('pyright-langserver'),
    args: ['--stdio'],
    workspaceConfig: {
      python: {
        pythonPath: '.venv/bin/python',
      },
    },
    rootSearch: [
      'pyrefly.toml',
      'pyproject.toml',
      'pyproject.yaml',
      'setup.py',
      'setup.cfg',
      'pyrightconfig.json',
      'Pipfile',
      'Pipfile.lock',
      'requirements.txt',
      '.venv/',
      '.git',
    ],
  }
enddef
