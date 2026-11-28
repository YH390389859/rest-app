// 显式列出全局 using，避免 WinForms / WPF / Drawing 的同名类型打架。
// 需要 System.Windows.Forms 的地方一律用 `using WinForms = System.Windows.Forms;` 起别名。
global using System;
global using System.Collections.Generic;
global using System.IO;
global using System.Linq;
global using System.Threading;
global using System.Threading.Tasks;
