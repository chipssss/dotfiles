-- Native Neovim LSP: no nvim-lspconfig wrapper is needed on Neovim 0.12.
-- The server executable is declared in home.nix for reproducible activation.
vim.lsp.config('typescript', {
  cmd = { 'typescript-language-server', '--stdio' },
  filetypes = {
    'javascript',
    'javascriptreact',
    'typescript',
    'typescriptreact',
  },
  root_markers = { 'tsconfig.json', 'jsconfig.json', 'package.json', '.git' },
  on_attach = function(_, bufnr)
    vim.keymap.set('n', 'gr', function()
      local snacks = rawget(_G, 'Snacks')
      if snacks and snacks.picker and snacks.picker.lsp_references then
        snacks.picker.lsp_references()
      else
        vim.lsp.buf.references()
      end
    end, {
      buffer = bufnr,
      desc = 'References',
    })
  end,
})

vim.lsp.enable('typescript')
